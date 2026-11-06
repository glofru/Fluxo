//
//  FluxoRemuxEngine.c
//  Fluxo
//
//  Built against the bundled FFmpeg 9 (Vendor/FFmpeg, see Tools/FFmpeg/build-xcframework.sh),
//  using only the public libavformat/libavcodec/libavutil API. Every demuxer, muxer, protocol and
//  bitstream filter the engine reaches must be enabled in that script.
//
//  Threading: everything except the public request functions runs on the engine thread.
//  Requests coming from other threads (cancel, recording) go through atomics and a mutex.
//

#include "FluxoRemuxEngine.h"
#include "FluxoTranscoder.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// FFmpeg's public headers trigger documentation warnings that are not ours to fix.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#pragma clang diagnostic pop

// Default limit for a single blocking read/connect.
#define FLUXO_DEFAULT_IO_TIMEOUT_US (15 * 1000000LL)
// Timestamp jumps larger than this (in AV_TIME_BASE units) are treated as discontinuities.
#define FLUXO_DISCONTINUITY_THRESHOLD (10 * AV_TIME_BASE)
// A live segment may end on a video key frame this much before its target duration: the key frames of a source cut
// every segment_duration seconds, but a timestamp discontinuity (joined without a gap) or jitter puts one a
// little early, and the segment would otherwise run on to the next one (twice the duration).
#define FLUXO_SEGMENT_CUT_TOLERANCE (AV_TIME_BASE / 10)
// Default number of consecutive reconnection attempts for live inputs.
#define FLUXO_DEFAULT_RECONNECT_ATTEMPTS 10
// Longest pause between two reconnection attempts.
#define FLUXO_MAX_RECONNECT_DELAY_US (8 * 1000000LL)
// Segments removed from the playlist are deleted only after this many newer removals, so that a
// player that just read the old playlist can still download them.
#define FLUXO_RETIRED_SEGMENTS 3
// Gap inserted between the last packet before a reconnection and the first one after it.
#define FLUXO_RECONNECT_GAP (AV_TIME_BASE / 10)
// Most audio and subtitle renditions of a master playlist (each kind).
#define FLUXO_MAX_RENDITIONS 16
// Subtitle cues waiting for the segment they belong to (a bound against inputs with broken timestamps).
#define FLUXO_MAX_PENDING_CUES 4096
// Duration given to a subtitle cue that has none.
#define FLUXO_DEFAULT_CUE_DURATION (4 * AV_TIME_BASE)
// Added to every output timestamp, so that the first decoding timestamps (which precede the first
// presentation timestamp by the B-frame delay) stay positive: fragmented MP4 cannot store negative times.
#define FLUXO_TIMESTAMP_BASE AV_TIME_BASE

// On-demand (VOD) inputs.
// Media produced ahead of the latest requested segment before reading pauses (resumes at half of it).
#define FLUXO_DEFAULT_READ_AHEAD 60.0
// A requested segment that starts at most this long after the one being read is reached by reading on; one
// farther away (or behind) is reached by seeking the input. In time rather than segments: reading on reads all the
// media in between at the speed of the network, and segments are as long as the GOPs of the input (often 10 s).
#define FLUXO_VOD_READ_ON_TIME (10 * AV_TIME_BASE)
// Consecutive attempts to resume an on-demand input after a read error (reopening it at the segment).
#define FLUXO_VOD_MAX_RECOVERIES 6
// Packets held while waiting for the key frame that starts the next segment (see fluxo_vod_route).
#define FLUXO_VOD_MAX_HELD_PACKETS 4096
// An index whose last key frame is this far from the end does not cover the input: segments are
// planned at nominal times instead.
#define FLUXO_VOD_INDEX_COVERAGE_GAP (60 * AV_TIME_BASE)
// An index with two consecutive key frames farther apart than this has holes (it lists only the key frames
// read so far): segments are planned at nominal times instead.
#define FLUXO_VOD_INDEX_MAX_KEY_GAP (20 * AV_TIME_BASE)
// Timestamps this close are equal (index and packet times are rescaled from the same time base).
#define FLUXO_VOD_TIME_EPSILON 1000
// A segment requested after fluxo_remux_note_seek is the one the seek goes to when it starts at most this long
// after the target (AVPlayer seeks with a tolerance of a quarter of a second, see PlayerSeeker).
#define FLUXO_VOD_SEEK_HINT_MARGIN (AV_TIME_BASE / 2)
// Plans without an index keep the packets read since the latest key frame of the video (references to them, at most
// this much media): a seek into a segment of that GOP starts it with its pre-roll from memory ("replays" them through
// fluxo_vod_route) instead of seeking the input back over the network for it. Beyond the limit (a very long GOP of a
// high bit rate), such a seek reads the GOP again from the network.
#define FLUXO_VOD_GOP_MEMORY_BYTES (48 * 1024 * 1024)
// After a seek into a segment that does not start with a key frame (MPEG-TS and other inputs without an index,
// planned at nominal times), the segment starts at the key frame before it (its "pre-roll"): otherwise its video
// could only begin at the next key frame, a GOP later, and the picture would stay frozen over the audio until then.
// The pre-roll holds at most this many packets; when the reader reaches the segment without having seen a key frame
// it seeks back this far once more (twice at most).
#define FLUXO_VOD_MAX_PREROLL_PACKETS 8192
#define FLUXO_VOD_PREROLL_BACKOFF (10 * AV_TIME_BASE)
#define FLUXO_VOD_MAX_PREROLL_BACKOFFS 2
// Inputs without an index (MPEG-TS) are seeked by byte position, estimated from the size and the duration: one
// request, where a seek by time searches the file with a dozen requests (seconds on a phone network). A landing more
// than FLUXO_VOD_BYTE_SEEK_LATE after the aimed time or FLUXO_VOD_BYTE_SEEK_EARLY before it is corrected (at most
// FLUXO_VOD_BYTE_SEEK_CORRECTIONS times), from the bit rate.
#define FLUXO_VOD_BYTE_SEEK_LATE (AV_TIME_BASE / 2)
#define FLUXO_VOD_BYTE_SEEK_EARLY (12 * AV_TIME_BASE)
#define FLUXO_VOD_BYTE_SEEK_CORRECTIONS 3

// Engine trace for the smoke tests (built with -DFLUXO_ENGINE_TRACE, printed when the FLUXO_ENGINE_TRACE
// environment variable is set). Compiled out of the app.
#ifdef FLUXO_ENGINE_TRACE
#define FLUXO_TRACE(...) do { if (getenv("FLUXO_ENGINE_TRACE") != NULL) { fprintf(stderr, "[engine] " __VA_ARGS__); fputc('\n', stderr); } } while (0)
#else
#define FLUXO_TRACE(...) do { } while (0)
#endif
// Buffer of the AVIOContext of on-demand HTTP inputs, and the longest forward seek made by reading on (a longer
// one opens a connection at the new position).
#define FLUXO_INPUT_IO_BUFFER (64 * 1024)
#define FLUXO_INPUT_IO_READ_ON (512 * 1024)

// MARK: - Types

// One muxer fed with the copied packets of the input.
typedef struct FluxoOutput {
    AVFormatContext *context;
    // Input stream index -> output stream index (-1 when the stream is not mapped).
    int *stream_map;
    unsigned int stream_map_size;
    // Last DTS written per output stream, in the output stream time base.
    int64_t *last_dts;
    // Output index of the video stream, or -1.
    int video_index;
    // Drop packets until the next video key frame so that the output starts decodable.
    int wait_keyframe;
    int header_written;
    // Which input streams the output copies. Zero (the default) is the first video stream and every audio
    // stream; renditions of a master playlist copy a single audio stream.
    int exclude_video;
    // 0: every audio stream, -1: none, n > 0: only the n-th audio stream of the input (1-based, counting the
    // streams fluxo_is_stream_supported accepts).
    int audio_selection;
    // Convert ADTS AAC (e.g. from MPEG-TS) to raw AAC with an AudioSpecificConfig (aac_adtstoasc), for
    // outputs whose muxer does not insert the filter itself. One filter per output stream, created at the
    // first packet that needs it.
    int convert_adts;
    AVBSFContext **filters;
    unsigned int filter_count;
} FluxoOutput;

// A subtitle cue waiting to be written to the WebVTT segments it overlaps. Times are output times
// (AV_TIME_BASE units, the timeline of the HLS segments).
typedef struct FluxoCue {
    int64_t start;
    int64_t end;
    char *text;
} FluxoCue;

typedef enum FluxoRenditionType {
    FluxoRenditionAudio = 0,
    FluxoRenditionSubtitles = 1,
} FluxoRenditionType;

// One EXT-X-MEDIA rendition of the master playlist.
typedef struct FluxoRendition {
    FluxoRenditionType type;
    // Position (0-based) of the source among the input's audio streams or text subtitle streams; it
    // finds the stream again after a reconnection.
    int ordinal;
    // Index of the source stream in the current input, -1 when the input no longer has it.
    int input_index;
    enum AVCodecID codec_id;
    // The default audio track: carried by the main media playlist, so the rendition has no URI.
    int muxed;
    int is_default;
    int forced;
    int hearing_impaired;
    int visual_impaired;
    int channels;
    char language[16];
    char name[128];
    // "<prefix>-a<n>" / "<prefix>-s<n>": the playlist is "<base>.m3u8", the segments "<base>-<sequence>.ts|vtt".
    char *base_path;
    // File name part of base_path.
    const char *base_name;
    char *playlist_path;
    char *playlist_tmp_path;
    // Audio: the muxer of its audio-only segments: MPEG-TS, or fragmented MP4 next to fMP4 video (AVPlayer
    // misplaces MPEG-TS audio against fMP4 video), with its own initialization segment "<base>-init.mp4".
    FluxoOutput output;
    int fragmented;
    char *init_path;
    int init_written;
    int moov_flushed;
    // Subtitles: cues that may still belong to the current or a later segment.
    FluxoCue *cues;
    int cue_count;
    int cue_capacity;
} FluxoRendition;

typedef struct FluxoSegment {
    int64_t sequence;
    double duration;
    int64_t bytes;
    int64_t wallclock_ms;
    int discontinuity;
} FluxoSegment;

typedef struct FluxoHLS {
    FluxoOutput output;
    char *playlist_path;
    char *playlist_tmp_path;
    char *segment_prefix;
    // File name part of segment_prefix (points into segment_prefix).
    const char *segment_base_name;
    // Fragmented MP4 segments ("m4s", with the initialization segment "<prefix>-init.mp4") instead of
    // MPEG-TS ("ts"). Chosen from the video codec when the output is created.
    int fragmented;
    const char *segment_extension;
    char *init_path;
    // The initialization segment exists (written once, by the first muxer of the session), and the
    // current muxer has written its moov (see fluxo_hls_flush).
    int init_written;
    int moov_flushed;
    double segment_duration;
    double max_window_duration;
    int64_t max_window_bytes;
    int min_window_segments;
    // Live playlists carry EXT-X-PROGRAM-DATE-TIME (wall clock of each segment); on-demand ones do not.
    int program_date_time;

    FluxoSegment *segments;
    int count;
    int capacity;
    double window_duration;
    int64_t window_bytes;
    int64_t discontinuity_sequence;
    int target_duration;

    int64_t retired[FLUXO_RETIRED_SEGMENTS];
    int retired_count;

    int64_t next_sequence;
    int64_t segments_written;

    // Current segment.
    int segment_open;
    int64_t segment_start_time;  // AV_TIME_BASE units, AV_NOPTS_VALUE until the first packet
    int64_t segment_wallclock_ms;
    int64_t last_reference_time;
    int segment_discontinuity;
    // The current segment was cut on the audio (converted video gave nothing): the next video key frame starts a
    // new segment whatever its duration, so that video segments follow that key frame's interval again.
    int segment_cut_on_audio;
    // Output stream used to decide where segments are cut (video if present).
    int reference_stream;

    // Master playlist (optional) and its renditions.
    char *master_path;
    char *master_tmp_path;
    int master_written;
    FluxoRendition *renditions;
    int rendition_count;
    int audio_rendition_count;
    int subtitle_rendition_count;
    // MPEG-TS timestamp (90 kHz) of output time 0 in the segments, for X-TIMESTAMP-MAP: the muxer shifts
    // every timestamp by its muxing delay.
    int64_t mpegts_time_zero;
    // The video of the first segment carries CEA-608/708 captions (ATSC A/53 user data).
    int closed_captions;
} FluxoHLS;

typedef struct FluxoRecording {
    FluxoOutput output;
    char *path;
    int active;
    int64_t first_time;
    int64_t last_time;
} FluxoRecording;

// A requested recording that was cancelled or replaced before the engine opened it. The engine
// still reports it (RecordingStopped) so that the caller always gets a terminal recording event.
typedef struct FluxoDiscardedRecording {
    char *path;
    struct FluxoDiscardedRecording *next;
} FluxoDiscardedRecording;

// The VOD playlist of an on-demand input: segment boundaries planned before playback starts.
typedef struct FluxoPlan {
    // count + 1 times (AV_TIME_BASE units, input timeline): segment i covers starts[i] to starts[i + 1].
    int64_t *starts;
    // Size on disk of each segment, 0 while it is not on disk. Guarded by vod_lock.
    int64_t *bytes;
    // Segments written without a picture while the encoder of converted video was refused (the app in the
    // background, Picture in Picture); deleted once pictures come again, so that they are written again with
    // them when the player asks. Engine thread only.
    uint8_t *blind;
    int blind_count;
    // Whether each segment on disk starts with a key frame of the video (a segment cut at its planned time inside
    // a GOP does not: it only plays after the segment before it). Guarded by vod_lock.
    uint8_t *independent;
    int count;
    // The boundaries are key frames of the input's index, so segments are exact and start with a key
    // frame; otherwise they are planned every segment_duration and cut at the next key frame.
    int exact;
    // Index times of this demuxer are decoding times (MP4, AVI); otherwise presentation times.
    int key_uses_dts;
    // Output stream used to decide cuts (the video, or the first audio stream), and its input stream.
    int reference_input_stream;
    int has_video;
} FluxoPlan;

// A packet held back until the cut between two segments is known.
typedef struct FluxoHeldPacket {
    AVPacket *packet;
    int64_t time;
} FluxoHeldPacket;

struct FluxoRemuxSession {
    char *input_url;
    char *user_agent;
    int64_t io_timeout_us;
    int is_live;
    int max_reconnect_attempts;
    // FluxoRemuxConfig.quick_open, and whether the first open of the input is in progress.
    int quick_open;
    int is_first_open;

    FluxoRemuxEventCallback callback;
    void *context;

    atomic_bool cancel_requested;
    atomic_bool started;
    pthread_t thread;
    int thread_created;

    // Recording requests from other threads.
    pthread_mutex_t request_lock;
    atomic_bool request_pending;
    char *pending_recording_path;
    int pending_recording_stop;
    FluxoDiscardedRecording *discarded_recordings;

    FluxoRemuxState state;
    int reconnect_attempt;
    // Set when the HLS output itself failed (disk full, ...): never recovered by reconnecting.
    int output_failed;

    AVFormatContext *input;
    // On-demand HTTP inputs are read through the engine's own AVIOContext (see fluxo_input_io_open), or NULL.
    struct FluxoInputIO *input_io;
    // What happens to each stream of the input (copied, converted, left out), and the converters.
    FluxoStreams streams;
    FluxoHLS hls;
    FluxoRecording recording;

    // Offset (AV_TIME_BASE units) added to every packet so that the output starts near zero
    // and stays continuous across input timestamp discontinuities and reconnections.
    int64_t timestamp_offset;
    int64_t last_input_dts;
    int rebase_pending;

    // MARK: On-demand inputs (is_live == 0)
    double read_ahead;
    // Where the player starts, from the start of the input (AV_TIME_BASE units, 0: the beginning).
    int64_t start_time;
    // A VOD plan exists (otherwise an on-demand input is remuxed from start to end, see fluxo_run_loop).
    int on_demand;
    FluxoPlan plan;
    // Guards the fields below that other threads read or write (fluxo_remux_request_segment).
    pthread_mutex_t vod_lock;
    pthread_cond_t vod_cond;
    // Latest segment the player requested, and a segment to seek to (-1: none). Guarded by vod_lock.
    int64_t vod_requested;
    int64_t vod_reposition;
    // Segment the reader is in, and the first segment it writes after a seek. Guarded by vod_lock.
    int64_t vod_segment;
    int64_t vod_target;
    // The input was read to its end; segments after vod_end_segment do not exist. Guarded by vod_lock.
    int vod_ended;
    int64_t vod_end_segment;
    int64_t vod_cached_bytes;
    // Engine thread only: the current segment's file is open (otherwise packets are skipped), the
    // output of the current run (one muxer per run of consecutive segments), packets held at a cut.
    // Segments listed so far (on-demand input without a plan) and the initialization segment exists.
    // Guarded by vod_lock.
    int64_t vod_available;
    int vod_init_ready;
    int64_t vod_segments_on_disk;
    // Reading paused because the reader is far enough ahead of the player.
    int vod_paused;
    // Counts the wake-ups of the engine thread (a segment request, a recording request, a cancellation), so a
    // paused reader sleeps until the next one instead of polling. Guarded by vod_lock.
    uint64_t vod_wakeups;
    // Disk budget of an on-demand input without a plan: its segments are all kept (its playlist grows), and
    // beyond this size reading pauses whenever it is read_ahead seconds ahead of the player.
    int64_t vod_budget_bytes;
    // Index reported with the next SegmentWritten event.
    int64_t event_segment_index;
    // The reader just seeked: the first packet of the reference stream shows whether it landed before the
    // target segment (MPEG-TS seeks by timestamp search, and can overshoot).
    int vod_check_seek;
    // Byte seeks of plans without an index (see fluxo_vod_seek): the time and byte position aimed at, and the
    // corrections made so far. vod_seek_position < 0 for a seek by time.
    int64_t vod_seek_time;
    int64_t vod_seek_position;
    int vod_seek_corrections;
    int vod_writing;
    int vod_need_key;
    // Video packets written to the current segment.
    int64_t vod_segment_pictures;
    int vod_recoveries;
    FluxoHeldPacket *vod_held;
    int vod_held_count;
    int vod_held_capacity;
    // Packets from the latest key frame before the target segment of a seek (see FLUXO_VOD_MAX_PREROLL_PACKETS),
    // and how often the reader seeked back for one.
    FluxoHeldPacket *vod_preroll;
    int vod_preroll_count;
    int vod_preroll_capacity;
    int vod_preroll_backoffs;
    // Engine thread only (plans without an index): every packet read since the latest key frame of the reference video,
    // in read order (FLUXO_VOD_GOP_MEMORY_BYTES; vod_kept_valid 0 until the next key frame when they do not fit), the
    // time of the latest packet read, and the packets fed to fluxo_vod_route again before the input is read on
    // (vod_replay_next is the next one).
    FluxoHeldPacket *vod_kept;
    int vod_kept_count;
    int vod_kept_capacity;
    int64_t vod_kept_bytes;
    int vod_kept_valid;
    int64_t vod_read_time;
    FluxoHeldPacket *vod_replay;
    int vod_replay_count;
    int vod_replay_capacity;
    int vod_replay_next;
    // The segment being written starts with a key frame of the video (see FluxoPlan.independent); its first video
    // packet is still to come.
    int vod_segment_independent;
    int vod_segment_awaits_video;
    // Longest GOP read so far (AV_TIME_BASE units, 0 before two key frames), and the latest key frame time: a seek
    // into a plan without an index starts this far before the target, so that it reads the key frame before it.
    int64_t vod_gop;
    int64_t vod_last_key;
    // A segment on disk that does not start with a key frame, requested by a seek: written again (with a pre-roll),
    // -1 when none. Guarded by vod_lock.
    int64_t vod_regenerate;
    // Where the player seeks to (playlist time, AV_TIME_BASE units; AV_NOPTS_VALUE: no seek), told by
    // fluxo_remux_note_seek before the player asks for the segment there. The next request of the main playlist
    // consumes it. Guarded by vod_lock.
    int64_t vod_seek_hint;
    // The VOD playlists are on disk (fluxo_remux_set_start_time may write them again). Guarded by vod_lock.
    int vod_playlist_written;
};

static pthread_once_t fluxo_init_once = PTHREAD_ONCE_INIT;

static void fluxo_global_init(void) {
    avformat_network_init();
    av_log_set_level(AV_LOG_ERROR);
}

static char *fluxo_strdup(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return NULL;
    }
    return strdup(value);
}

static int64_t fluxo_wallclock_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int fluxo_is_cancelled(FluxoRemuxSession *session) {
    return atomic_load(&session->cancel_requested) ? 1 : 0;
}

static int fluxo_interrupt_callback(void *opaque) {
    return fluxo_is_cancelled(opaque);
}

// Audio and video the outputs take: not cover art, nor a stream the engine left out (fluxo_streams_open discards
// streams that can neither be copied nor converted, and video after the first playable one).
static int fluxo_is_stream_supported(const AVStream *stream) {
    if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) || stream->discard >= AVDISCARD_ALL) {
        return 0;
    }
    enum AVMediaType type = stream->codecpar->codec_type;
    return type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
}

// MARK: - Events

// `explicit_path` reports a recording that was never opened; otherwise the active recording is reported.
static void fluxo_emit_with_path(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message,
                                 const char *explicit_path) {
    if (session->callback == NULL) {
        return;
    }
    FluxoRemuxEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = kind;
    event.state = session->state;
    event.error_code = (int32_t)error_code;
    event.message = message;
    event.reconnect_attempt = session->state == FluxoRemuxStateReconnecting ? session->reconnect_attempt : 0;
    event.segments_written = session->hls.segments_written;
    event.window_segment_count = session->hls.count;
    event.window_duration = session->hls.window_duration;
    event.window_bytes = session->hls.window_bytes;
    event.master_playlist_written = session->hls.master_written;
    event.audio_rendition_count = session->hls.master_written ? session->hls.audio_rendition_count : 0;
    event.subtitle_rendition_count = session->hls.master_written ? session->hls.subtitle_rendition_count : 0;
    event.segment_index = session->event_segment_index;
    if (session->on_demand) {
        // On-demand: the segments on disk and their size; the duration of the whole playlist.
        event.window_segment_count = (int32_t)session->vod_segments_on_disk;
        event.window_duration = session->plan.count > 0 ? (double)(session->plan.starts[session->plan.count] - session->plan.starts[0]) / AV_TIME_BASE : 0;
        event.window_bytes = session->vod_cached_bytes;
    }

    FluxoRecording *recording = &session->recording;
    if (explicit_path != NULL) {
        event.recording_path = explicit_path;
    } else if (recording->path != NULL) {
        event.recording_path = recording->path;
        if (recording->first_time != AV_NOPTS_VALUE && recording->last_time != AV_NOPTS_VALUE) {
            event.recording_duration = (double)(recording->last_time - recording->first_time) / AV_TIME_BASE;
        }
        if (recording->output.context != NULL && recording->output.context->pb != NULL) {
            event.recording_bytes = avio_tell(recording->output.context->pb);
        }
    }
    session->callback(session->context, &event);
}

static void fluxo_emit(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message) {
    fluxo_emit_with_path(session, kind, error_code, message, NULL);
}

static void fluxo_set_state(FluxoRemuxSession *session, FluxoRemuxState state, int error_code, const char *message) {
    session->state = state;
    fluxo_emit(session, FluxoRemuxEventStateChanged, error_code, message);
}

static void fluxo_format_error(char *buffer, size_t size, int error_code, const char *what) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(error_code, reason, sizeof(reason));
    snprintf(buffer, size, "%s: %s", what, reason);
}

// "Protocol not found" names neither the protocol nor the cause; say which URL scheme the bundled
// FFmpeg cannot open (Tools/FFmpeg/build-xcframework.sh lists the protocols it has).
static void fluxo_format_unsupported_protocol(char *buffer, size_t size, const char *url) {
    const char *separator = url != NULL ? strstr(url, "://") : NULL;
    int length = separator != NULL ? (int)(separator - url) : 0;
    if (length > 0 && length <= 16) {
        snprintf(buffer, size, "Unsupported stream type: %.*s:// streams cannot be played", length, url);
    } else {
        snprintf(buffer, size, "Unsupported stream type");
    }
}

// MARK: - Input

static void fluxo_close_input(FluxoRemuxSession *session);
static int fluxo_is_busy_server_error(int error);
static void fluxo_wait(FluxoRemuxSession *session, int64_t duration_us);

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

static int fluxo_open_input(FluxoRemuxSession *session) {
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

// Errors of a server that may accept the connection a moment later: refused for the number of connections of the
// account (403, 429 and other 4xx IPTV panels use, 5xx), reset or timed out. Not a missing stream (404) or bad
// credentials (401).
static int fluxo_is_busy_server_error(int error) {
    return error == AVERROR_HTTP_FORBIDDEN || error == AVERROR_HTTP_TOO_MANY_REQUESTS || error == AVERROR_HTTP_OTHER_4XX ||
           error == AVERROR_HTTP_SERVER_ERROR || error == AVERROR(ECONNRESET) || error == AVERROR(ECONNREFUSED) ||
           error == AVERROR(ETIMEDOUT) || error == AVERROR(EIO);
}

// True when the input has a known size and everything up to it was read. Live inputs have no
// size (or an unreachable placeholder size), so an EOF there means the connection was lost.
static int fluxo_input_reached_end_of_file(FluxoRemuxSession *session) {
    if (session->input == NULL || session->input->pb == NULL) {
        return 0;
    }
    int64_t size = avio_size(session->input->pb);
    return size > 0 && avio_tell(session->input->pb) >= size;
}

static void fluxo_close_input(FluxoRemuxSession *session) {
    AVIOContext *pb = session->input != NULL && session->input_io != NULL ? session->input->pb : NULL;
    fluxo_streams_close(&session->streams);
    if (session->input != NULL) {
        avformat_close_input(&session->input);
    }
    // A custom AVIOContext is not closed by avformat_close_input.
    fluxo_input_io_close(&pb, &session->input_io);
}

// MARK: - Outputs

static void fluxo_output_free(FluxoOutput *output) {
    if (output->context != NULL) {
        if (output->context->pb != NULL && !(output->context->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output->context->pb);
        }
        avformat_free_context(output->context);
        output->context = NULL;
    }
    free(output->stream_map);
    output->stream_map = NULL;
    output->stream_map_size = 0;
    if (output->filters != NULL) {
        for (unsigned int i = 0; i < output->filter_count; i++) {
            av_bsf_free(&output->filters[i]);
        }
        free(output->filters);
        output->filters = NULL;
    }
    output->filter_count = 0;
    output->convert_adts = 0;
    free(output->last_dts);
    output->last_dts = NULL;
    output->header_written = 0;
    output->video_index = -1;
    output->wait_keyframe = 0;
}

// Whether `output` copies `stream`, the `audio_ordinal`-th supported audio stream of its input when it is audio.
static int fluxo_output_selects(const FluxoOutput *output, const AVStream *stream, int audio_ordinal) {
    if (!fluxo_is_stream_supported(stream)) {
        return 0;
    }
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        return !output->exclude_video;
    }
    if (output->audio_selection < 0) {
        return 0;
    }
    return output->audio_selection == 0 || output->audio_selection == audio_ordinal + 1;
}

// Maps the streams of `input` to the existing output streams with the same media type and codec.
// Returns the number of mapped streams or a negative error.
static int fluxo_output_map_input(FluxoOutput *output, AVFormatContext *input) {
    int *map = realloc(output->stream_map, sizeof(int) * (input->nb_streams > 0 ? input->nb_streams : 1));
    if (map == NULL) {
        return AVERROR(ENOMEM);
    }
    output->stream_map = map;
    output->stream_map_size = input->nb_streams;

    unsigned int output_count = output->context->nb_streams;
    char *used = calloc(output_count > 0 ? output_count : 1, 1);
    if (used == NULL) {
        return AVERROR(ENOMEM);
    }

    int mapped = 0;
    int audio_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        map[i] = -1;
        AVStream *in_stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(in_stream) && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int selected = fluxo_output_selects(output, in_stream, audio_ordinal);
        if (is_audio) {
            audio_ordinal++;
        }
        if (!selected) {
            continue;
        }
        const AVCodecParameters *in_par = fluxo_stream_parameters(input, i);
        for (unsigned int j = 0; j < output_count; j++) {
            AVCodecParameters *out_par = output->context->streams[j]->codecpar;
            if (!used[j] && out_par->codec_type == in_par->codec_type && out_par->codec_id == in_par->codec_id) {
                used[j] = 1;
                map[i] = (int)j;
                mapped++;
                break;
            }
        }
    }
    free(used);
    return mapped;
}

// Allocates an output of `format_name` with a copy of the streams `output` selects (by default the first video
// stream and every audio stream). The file itself is not opened.
static int fluxo_output_prepare(FluxoOutput *output, AVFormatContext *input, const char *format_name, const char *path) {
    output->video_index = -1;
    int ret = avformat_alloc_output_context2(&output->context, NULL, format_name, path);
    if (ret < 0 || output->context == NULL) {
        return ret < 0 ? ret : AVERROR_UNKNOWN;
    }
    // Outputs are local files and intentionally have no interrupt callback: after a cancellation
    // the trailer must still be written so that segments and recordings are finalized cleanly.

    int is_mp4 = strcmp(output->context->oformat->name, "mp4") == 0 || strcmp(output->context->oformat->name, "mov") == 0;
    int audio_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *in_stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(in_stream) && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int selected = fluxo_output_selects(output, in_stream, audio_ordinal);
        if (is_audio) {
            audio_ordinal++;
        }
        if (!selected) {
            continue;
        }
        // HLS players expect a single video rendition per variant.
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && output->video_index >= 0) {
            continue;
        }
        // The parameters of what is written: a converted stream's (AAC, H.264), otherwise the input's.
        const AVCodecParameters *in_par = fluxo_stream_parameters(input, i);
        // A codec the container cannot carry would fail the whole header: leave that stream out.
        if (is_mp4 && avformat_query_codec(output->context->oformat, in_par->codec_id, FF_COMPLIANCE_NORMAL) != 1) {
            continue;
        }
        AVStream *out_stream = avformat_new_stream(output->context, NULL);
        if (out_stream == NULL) {
            return AVERROR(ENOMEM);
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_par);
        if (ret < 0) {
            return ret;
        }
        out_stream->codecpar->codec_tag = 0;
        if (is_mp4 && in_par->codec_id == AV_CODEC_ID_HEVC) {
            // AVFoundation only plays HEVC in MP4 with the hvc1 sample entry.
            out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
        }
        out_stream->time_base = in_stream->time_base;
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            output->video_index = out_stream->index;
        }
    }

    if (output->context->nb_streams == 0) {
        return AVERROR_STREAM_NOT_FOUND;
    }
    output->last_dts = malloc(sizeof(int64_t) * output->context->nb_streams);
    if (output->last_dts == NULL) {
        return AVERROR(ENOMEM);
    }
    for (unsigned int j = 0; j < output->context->nb_streams; j++) {
        output->last_dts[j] = AV_NOPTS_VALUE;
    }
    output->wait_keyframe = output->video_index >= 0;

    ret = fluxo_output_map_input(output, input);
    return ret < 0 ? ret : 0;
}

// Converts an ADTS packet of output stream `index` in place. Returns 1 when `scratch` holds the converted
// packet (the first one carries the AudioSpecificConfig as new extradata), 0 when it must be skipped.
static int fluxo_output_convert_adts(FluxoOutput *output, int index, AVPacket *scratch) {
    unsigned int count = output->context->nb_streams;
    if (output->filters == NULL) {
        output->filters = calloc(count, sizeof(AVBSFContext *));
        if (output->filters == NULL) {
            return AVERROR(ENOMEM);
        }
        output->filter_count = count;
    }
    AVBSFContext *filter = output->filters[index];
    if (filter == NULL) {
        const AVBitStreamFilter *definition = av_bsf_get_by_name("aac_adtstoasc");
        if (definition == NULL) {
            return AVERROR_BSF_NOT_FOUND;
        }
        int ret = av_bsf_alloc(definition, &filter);
        if (ret < 0) {
            return ret;
        }
        AVStream *stream = output->context->streams[index];
        ret = avcodec_parameters_copy(filter->par_in, stream->codecpar);
        if (ret >= 0) {
            filter->time_base_in = stream->time_base;
            ret = av_bsf_init(filter);
        }
        if (ret < 0) {
            av_bsf_free(&filter);
            return ret;
        }
        output->filters[index] = filter;
    }
    int ret = av_bsf_send_packet(filter, scratch);
    if (ret < 0) {
        // A damaged frame: drop it, not the stream.
        return 0;
    }
    ret = av_bsf_receive_packet(filter, scratch);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    }
    if (ret < 0) {
        return 0;
    }
    scratch->stream_index = index;
    return 1;
}

// Copies `packet` (input time base, already adjusted) into `scratch` for `output`.
// Returns 1 when `scratch` must be written, 0 when the packet is skipped, a negative value on errors.
static int fluxo_output_prepare_packet(FluxoOutput *output, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    if (!output->header_written || packet->stream_index < 0 || (unsigned int)packet->stream_index >= output->stream_map_size) {
        return 0;
    }
    int out_index = output->stream_map[packet->stream_index];
    if (out_index < 0) {
        return 0;
    }
    if (output->wait_keyframe) {
        if (out_index != output->video_index || !(packet->flags & AV_PKT_FLAG_KEY)) {
            return 0;
        }
        output->wait_keyframe = 0;
    }
    AVStream *out_stream = output->context->streams[out_index];

    int ret = av_packet_ref(scratch, packet);
    if (ret < 0) {
        return ret;
    }
    scratch->stream_index = out_index;
    av_packet_rescale_ts(scratch, in_stream->time_base, out_stream->time_base);
    scratch->pos = -1;

    if (output->convert_adts && out_stream->codecpar->codec_id == AV_CODEC_ID_AAC && scratch->size > 2 &&
        scratch->data[0] == 0xff && (scratch->data[1] & 0xf0) == 0xf0) {
        ret = fluxo_output_convert_adts(output, out_index, scratch);
        if (ret <= 0) {
            av_packet_unref(scratch);
            return ret;
        }
    }

    // Muxers reject non monotonic DTS; drop late packets and nudge duplicates.
    int64_t last = output->last_dts[out_index];
    if (scratch->dts != AV_NOPTS_VALUE && last != AV_NOPTS_VALUE) {
        if (scratch->dts < last) {
            av_packet_unref(scratch);
            return 0;
        }
        if (scratch->dts == last) {
            scratch->dts = last + 1;
            if (scratch->pts != AV_NOPTS_VALUE && scratch->pts < scratch->dts) {
                scratch->pts = scratch->dts;
            }
        }
    }
    return 1;
}

// Writes a packet prepared by fluxo_output_prepare_packet. `scratch` is always reset.
static int fluxo_output_commit(FluxoOutput *output, AVPacket *scratch) {
    if (scratch->dts != AV_NOPTS_VALUE) {
        output->last_dts[scratch->stream_index] = scratch->dts;
    }
    // The input is already interleaved by the demuxer, so packets are written directly. This keeps
    // the HLS segment boundaries exact (no packet waits in an interleaving queue).
    int ret = av_write_frame(output->context, scratch);
    av_packet_unref(scratch);
    if (ret == AVERROR(EINVAL)) {
        // Invalid timestamps on a single packet should not stop a live stream.
        return 0;
    }
    return ret < 0 ? ret : 0;
}

static int64_t fluxo_packet_time(const AVPacket *packet, const AVStream *stream) {
    int64_t ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (ts == AV_NOPTS_VALUE) {
        return AV_NOPTS_VALUE;
    }
    return av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q);
}

// MARK: - HLS segmenter

static void fluxo_hls_segment_path(const FluxoHLS *hls, int64_t sequence, int temporary, char *buffer, size_t size) {
    snprintf(buffer, size, "%s-%06lld.%s%s", hls->segment_prefix, (long long)sequence, hls->segment_extension, temporary ? ".tmp" : "");
}

// AVPlayer decodes HEVC from HLS only in fragmented MP4 (from MPEG-TS segments it plays the audio
// over a black picture), so HEVC video gets fMP4 segments, and so does AV1 (which MPEG-TS cannot carry);
// everything else (converted video included: H.264) stays MPEG-TS.
static int fluxo_hls_wants_fragmented_mp4(const AVFormatContext *input) {
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && fluxo_is_stream_supported(stream)) {
            enum AVCodecID codec_id = fluxo_stream_parameters(input, i)->codec_id;
            return codec_id == AV_CODEC_ID_HEVC || codec_id == AV_CODEC_ID_AV1;
        }
    }
    return 0;
}

// Header options of the fragmented MP4 muxers (the main output of HEVC video and its audio renditions): one
// fragment per segment, flushed by the segmenter (frag_custom); the moov written at the first flush
// (delay_moov: AC-3 / E-AC-3 tracks need packets before their sample entry can be written), into the
// initialization segment; fragments addressed from their own moof, so they can be stored as separate files; no
// edit list and no timestamp shift, so that the tfdt of every fragment is its real decoding time, also for the
// first fragment after a seek (frag_discont).
static AVDictionary *fluxo_fragmented_options(void) {
    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", "+frag_custom+delay_moov+default_base_moof+frag_discont+skip_trailer", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    return options;
}

// Writes the muxer header: into the open segment for MPEG-TS; nowhere for fragmented MP4, whose header
// is the moov written at the first flush (fluxo_output_flush).
static int fluxo_output_write_header(FluxoOutput *output, int fragmented) {
    AVFormatContext *context = output->context;
    int ret;
    if (!fragmented) {
        ret = avformat_write_header(context, NULL);
    } else {
        AVDictionary *options = fluxo_fragmented_options();
        AVIOContext *segment = context->pb;
        ret = avio_open_dyn_buf(&context->pb);
        if (ret >= 0) {
            ret = avformat_write_header(context, &options);
            uint8_t *discarded = NULL;
            avio_close_dyn_buf(context->pb, &discarded);
            av_free(discarded);
        }
        context->pb = segment;
        av_dict_free(&options);
    }
    if (ret >= 0) {
        output->header_written = 1;
    }
    return ret < 0 ? ret : 0;
}

// Writes the packets buffered for the current segment into its file. The first flush of a fragmented MP4
// muxer writes only the ftyp and moov (delay_moov): the first time into the initialization segment
// `init_path`, later (every run of an on-demand input has the same moov) into a discarded buffer; then the
// fragment follows.
static int fluxo_output_flush(FluxoOutput *output, int fragmented, const char *init_path, int *init_written, int *moov_flushed) {
    AVFormatContext *context = output->context;
    if (!fragmented) {
        int ret = av_write_frame(context, NULL);
        return ret < 0 ? ret : 0;
    }
    if (!*moov_flushed) {
        AVIOContext *segment = context->pb;
        char temporary[PATH_MAX];
        snprintf(temporary, sizeof(temporary), "%s.tmp", init_path);
        int write_init = !*init_written;
        int ret = write_init ? avio_open(&context->pb, temporary, AVIO_FLAG_WRITE) : avio_open_dyn_buf(&context->pb);
        if (ret >= 0) {
            ret = av_write_frame(context, NULL);
            if (write_init) {
                avio_flush(context->pb);
                if (avio_closep(&context->pb) < 0 && ret >= 0) {
                    ret = AVERROR(EIO);
                }
                if (ret >= 0 && rename(temporary, init_path) != 0) {
                    ret = AVERROR(errno);
                }
                if (ret < 0) {
                    unlink(temporary);
                } else {
                    *init_written = 1;
                }
            } else {
                uint8_t *discarded = NULL;
                avio_close_dyn_buf(context->pb, &discarded);
                av_free(discarded);
            }
        }
        context->pb = segment;
        if (ret < 0) {
            return ret;
        }
        *moov_flushed = 1;
    }
    int ret = av_write_frame(context, NULL);
    return ret < 0 ? ret : 0;
}

// Muxing delay of the MPEG-TS outputs of a master playlist. The main output and the audio renditions are
// separate muxers, so they must put the same timestamps on the same media: an explicit delay, and no
// automatic shift of negative timestamps (libavformat would shift each muxer by its own first packet).
// Fragmented MP4 outputs (HEVC video and its audio renditions) write their timestamps as they are.
#define FLUXO_RENDITION_MUX_DELAY 700000

// Aligns an MPEG-TS muxer of a master playlist (the main output or an audio rendition), see above, and sets
// the time of output time 0 in the segments, for the X-TIMESTAMP-MAP of the WebVTT segments: the MPEG-TS
// muxer adds twice its maximum delay to every timestamp (90 kHz clock). With fragmented MP4 it stays 0: the
// map then refers to the media timeline itself.
static void fluxo_hls_align_muxer(FluxoHLS *hls, AVFormatContext *context) {
    context->max_delay = FLUXO_RENDITION_MUX_DELAY;
    context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    hls->mpegts_time_zero = av_rescale(FLUXO_RENDITION_MUX_DELAY, 90000, AV_TIME_BASE) * 2;
}

// Allocates the HLS muxer for the input. The caller opens the segment file and writes the header.
static int fluxo_hls_prepare_output(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    hls->fragmented = fluxo_hls_wants_fragmented_mp4(session->input);
    hls->segment_extension = hls->fragmented ? "m4s" : "ts";
    hls->moov_flushed = 0;
    int ret = fluxo_output_prepare(&hls->output, session->input, hls->fragmented ? "mp4" : "mpegts", NULL);
    if (ret < 0) {
        return ret;
    }
    // Timestamps are positive (FLUXO_TIMESTAMP_BASE) and are kept as they are: segments of different
    // runs of an on-demand input (after a seek) are placed by their own timestamps.
    hls->output.context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    // The MP4 muxer does not insert aac_adtstoasc itself when the moov comes first.
    hls->output.convert_adts = hls->fragmented;
    if (hls->rendition_count > 0 && !hls->fragmented) {
        fluxo_hls_align_muxer(hls, hls->output.context);
    }
    return 0;
}

static int fluxo_hls_write_header(FluxoHLS *hls) {
    return fluxo_output_write_header(&hls->output, hls->fragmented);
}

static int fluxo_hls_flush(FluxoHLS *hls) {
    return fluxo_output_flush(&hls->output, hls->fragmented, hls->init_path, &hls->init_written, &hls->moov_flushed);
}

static void fluxo_hls_delete_rendition_segments(const FluxoHLS *hls, int64_t sequence);

static void fluxo_hls_delete_segment(const FluxoHLS *hls, int64_t sequence) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, sequence, 0, path, sizeof(path));
    unlink(path);
    fluxo_hls_delete_rendition_segments(hls, sequence);
}

static void fluxo_hls_retire(FluxoHLS *hls, int64_t sequence) {
    if (hls->retired_count == FLUXO_RETIRED_SEGMENTS) {
        fluxo_hls_delete_segment(hls, hls->retired[0]);
        memmove(hls->retired, hls->retired + 1, sizeof(int64_t) * (FLUXO_RETIRED_SEGMENTS - 1));
        hls->retired_count--;
    }
    hls->retired[hls->retired_count++] = sequence;
}

// Drops the oldest segments while the window is over its duration or size limit.
static void fluxo_hls_prune(FluxoHLS *hls) {
    int removed = 0;
    while (hls->count - removed > hls->min_window_segments) {
        int over_duration = hls->max_window_duration > 0 && hls->window_duration > hls->max_window_duration;
        int over_size = hls->max_window_bytes > 0 && hls->window_bytes > hls->max_window_bytes;
        if (!over_duration && !over_size) {
            break;
        }
        FluxoSegment *oldest = &hls->segments[removed];
        hls->window_duration -= oldest->duration;
        hls->window_bytes -= oldest->bytes;
        if (oldest->discontinuity) {
            hls->discontinuity_sequence++;
        }
        fluxo_hls_retire(hls, oldest->sequence);
        removed++;
    }
    if (removed > 0) {
        hls->count -= removed;
        memmove(hls->segments, hls->segments + removed, sizeof(FluxoSegment) * (size_t)hls->count);
    }
}

// Writes one media playlist of the window: the main one, or a rendition's (same segments, other files).
static const char *fluxo_rendition_extension(const FluxoRendition *rendition);

// `init_path`: the initialization segment of fragmented MP4 segments (EXT-X-MAP), NULL for MPEG-TS and WebVTT.
static int fluxo_hls_write_media_playlist(FluxoHLS *hls, const char *path, const char *tmp_path, const char *base_name,
                                          const char *extension, const char *init_path, int independent, int ended) {
    FILE *file = fopen(tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int64_t media_sequence = hls->count > 0 ? hls->segments[0].sequence : hls->next_sequence;
    int unlimited = hls->max_window_duration <= 0 && hls->max_window_bytes <= 0;

    // fMP4 segments (EXT-X-MAP in a media playlist without I-frames only) need version 6; 7 is what
    // Apple's tools write for them.
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:%d\n", init_path != NULL ? 7 : 3);
    fprintf(file, "#EXT-X-TARGETDURATION:%d\n", hls->target_duration);
    fprintf(file, "#EXT-X-MEDIA-SEQUENCE:%lld\n", (long long)media_sequence);
    if (hls->discontinuity_sequence > 0) {
        fprintf(file, "#EXT-X-DISCONTINUITY-SEQUENCE:%lld\n", (long long)hls->discontinuity_sequence);
    }
    if (unlimited) {
        // Nothing is ever removed: lets players seek back to the very beginning.
        fprintf(file, "#EXT-X-PLAYLIST-TYPE:EVENT\n");
        if (!hls->program_date_time) {
            // An on-demand input still being read: AVPlayer would join a growing playlist near its end,
            // like a live stream; a movie starts at its beginning.
            fprintf(file, "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n");
        }
    }
    if (independent) {
        fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    }
    if (init_path != NULL) {
        const char *slash = strrchr(init_path, '/');
        fprintf(file, "#EXT-X-MAP:URI=\"%s\"\n", slash != NULL ? slash + 1 : init_path);
    }
    for (int i = 0; i < hls->count; i++) {
        const FluxoSegment *segment = &hls->segments[i];
        if (segment->discontinuity) {
            fprintf(file, "#EXT-X-DISCONTINUITY\n");
        }
        if (hls->program_date_time) {
            time_t seconds = (time_t)(segment->wallclock_ms / 1000);
            struct tm utc;
            gmtime_r(&seconds, &utc);
            char date[32];
            strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &utc);
            fprintf(file, "#EXT-X-PROGRAM-DATE-TIME:%s.%03dZ\n", date, (int)(segment->wallclock_ms % 1000));
        }
        fprintf(file, "#EXTINF:%.3f,\n%s-%06lld.%s\n", segment->duration, base_name, (long long)segment->sequence, extension);
    }
    if (ended) {
        fprintf(file, "#EXT-X-ENDLIST\n");
    }
    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(tmp_path);
        return AVERROR(EIO);
    }
    // Atomic replacement: the HTTP server never serves a partially written playlist.
    if (rename(tmp_path, path) != 0) {
        return AVERROR(errno);
    }
    return 0;
}

// Rewrites the playlists of the renditions, then the main one, so that no rendition is ever behind it.
static int fluxo_hls_write_playlist(FluxoHLS *hls, int ended) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        int is_audio = rendition->type == FluxoRenditionAudio;
        int ret = fluxo_hls_write_media_playlist(hls, rendition->playlist_path, rendition->playlist_tmp_path, rendition->base_name,
                                                 fluxo_rendition_extension(rendition), rendition->fragmented ? rendition->init_path : NULL,
                                                 is_audio, ended);
        if (ret < 0) {
            return ret;
        }
    }
    return fluxo_hls_write_media_playlist(hls, hls->playlist_path, hls->playlist_tmp_path, hls->segment_base_name,
                                          hls->segment_extension, hls->fragmented ? hls->init_path : NULL,
                                          hls->output.video_index >= 0, ended);
}

// MARK: - Renditions (alternative audio and subtitles)

static int fluxo_is_text_subtitle(enum AVCodecID codec_id) {
    switch (codec_id) {
    case AV_CODEC_ID_SUBRIP:
    case AV_CODEC_ID_TEXT:
    case AV_CODEC_ID_ASS:
    case AV_CODEC_ID_SSA:
    case AV_CODEC_ID_WEBVTT:
    case AV_CODEC_ID_MOV_TEXT:
        return 1;
    default:
        return 0;
    }
}

// Audio codecs HLS players decode (Apple's HLS authoring specification): only these become renditions.
// MPEG-1 Layer II (DVB channels; on iOS it is converted to AAC) and others stay out of the master playlist:
// AVPlayer on iOS fails the whole item when it switches to one ("fmt?"). Converted streams are AAC.
static int fluxo_is_hls_audio(const AVFormatContext *input, unsigned int index) {
    switch (fluxo_stream_parameters(input, index)->codec_id) {
    case AV_CODEC_ID_AAC:
    case AV_CODEC_ID_AC3:
    case AV_CODEC_ID_EAC3:
    case AV_CODEC_ID_MP3:
        return 1;
    default:
        return 0;
    }
}

static int fluxo_is_subtitle_source(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && fluxo_is_text_subtitle(stream->codecpar->codec_id);
}

// The input stream of `rendition` in `input`, or -1.
static int fluxo_rendition_find_source(const FluxoRendition *rendition, const AVFormatContext *input) {
    int ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        int matches = rendition->type == FluxoRenditionAudio
            ? fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            : fluxo_is_subtitle_source(stream);
        if (!matches) {
            continue;
        }
        if (ordinal == rendition->ordinal) {
            if (rendition->type == FluxoRenditionSubtitles && stream->codecpar->codec_id != rendition->codec_id) {
                return -1;
            }
            return (int)i;
        }
        ordinal++;
    }
    return -1;
}

// ISO 639-2 (bibliographic or terminology) codes of the languages that have an ISO 639-1 code, which
// BCP 47 (the HLS LANGUAGE attribute) prefers. Other three-letter codes are valid BCP 47 as they are.
static const char *const fluxo_language_codes[][2] = {
    {"alb", "sq"}, {"ara", "ar"}, {"arm", "hy"}, {"aze", "az"}, {"baq", "eu"}, {"bel", "be"}, {"ben", "bn"},
    {"bos", "bs"}, {"bul", "bg"}, {"bur", "my"}, {"cat", "ca"}, {"ces", "cs"}, {"chi", "zh"}, {"cym", "cy"},
    {"cze", "cs"}, {"dan", "da"}, {"deu", "de"}, {"dut", "nl"}, {"ell", "el"}, {"eng", "en"}, {"est", "et"},
    {"eus", "eu"}, {"fas", "fa"}, {"fin", "fi"}, {"fra", "fr"}, {"fre", "fr"}, {"geo", "ka"}, {"ger", "de"},
    {"gle", "ga"}, {"glg", "gl"}, {"gre", "el"}, {"guj", "gu"}, {"heb", "he"}, {"hin", "hi"}, {"hrv", "hr"},
    {"hun", "hu"}, {"hye", "hy"}, {"ice", "is"}, {"ind", "id"}, {"isl", "is"}, {"ita", "it"}, {"jpn", "ja"},
    {"kan", "kn"}, {"kat", "ka"}, {"kaz", "kk"}, {"khm", "km"}, {"kor", "ko"}, {"kur", "ku"}, {"lao", "lo"},
    {"lat", "la"}, {"lav", "lv"}, {"lit", "lt"}, {"ltz", "lb"}, {"mac", "mk"}, {"mal", "ml"}, {"mar", "mr"},
    {"may", "ms"}, {"mkd", "mk"}, {"mlt", "mt"}, {"mon", "mn"}, {"msa", "ms"}, {"mya", "my"}, {"nep", "ne"},
    {"nld", "nl"}, {"nob", "nb"}, {"nno", "nn"}, {"nor", "no"}, {"pan", "pa"}, {"per", "fa"}, {"pol", "pl"},
    {"por", "pt"}, {"pus", "ps"}, {"ron", "ro"}, {"rum", "ro"}, {"rus", "ru"}, {"sin", "si"}, {"slk", "sk"},
    {"slo", "sk"}, {"slv", "sl"}, {"som", "so"}, {"spa", "es"}, {"sqi", "sq"}, {"srp", "sr"}, {"swa", "sw"},
    {"swe", "sv"}, {"tam", "ta"}, {"tel", "te"}, {"tgl", "tl"}, {"tha", "th"}, {"tur", "tr"}, {"ukr", "uk"},
    {"urd", "ur"}, {"uzb", "uz"}, {"vie", "vi"}, {"wel", "cy"}, {"zho", "zh"},
};

// The BCP 47 tag of a stream's "language" tag ("eng" -> "en", "pt-BR" stays), or "" when it has none.
static void fluxo_language_tag(const char *language, char *buffer, size_t size) {
    buffer[0] = '\0';
    if (language == NULL) {
        return;
    }
    char lower[16];
    size_t length = 0;
    for (const char *c = language; *c != '\0' && length + 1 < sizeof(lower); c++) {
        char ch = *c;
        if (ch == '_') {
            ch = '-';
        }
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-')) {
            return;
        }
        lower[length++] = (ch >= 'A' && ch <= 'Z') ? (char)(ch - 'A' + 'a') : ch;
    }
    lower[length] = '\0';
    // "und" (undetermined), "mis", "mul", "zxx" and "qaa"-"qtz" (local use) name no language.
    if (length == 0 || strcmp(lower, "und") == 0 || strcmp(lower, "mis") == 0 || strcmp(lower, "mul") == 0
        || strcmp(lower, "zxx") == 0 || (length == 3 && lower[0] == 'q' && lower[1] >= 'a' && lower[1] <= 't')) {
        return;
    }
    if (length == 3) {
        for (size_t i = 0; i < sizeof(fluxo_language_codes) / sizeof(fluxo_language_codes[0]); i++) {
            if (strcmp(lower, fluxo_language_codes[i][0]) == 0) {
                snprintf(buffer, size, "%s", fluxo_language_codes[i][1]);
                return;
            }
        }
    }
    snprintf(buffer, size, "%s", lower);
}

// Copies a stream title into a quoted-string of a playlist attribute: no quotes, no control characters,
// cut at a UTF-8 character boundary.
static void fluxo_attribute_text(const char *text, char *buffer, size_t size) {
    size_t length = 0;
    if (text != NULL) {
        const unsigned char *c = (const unsigned char *)text;
        for (; *c != '\0' && length + 1 < size; c++) {
            unsigned char ch = *c;
            if (ch < 0x20 || ch == 0x7F) {
                ch = ' ';
            } else if (ch == '"') {
                ch = '\'';
            }
            buffer[length++] = (char)ch;
        }
        // When the text was cut, do not end in the middle of a multi-byte character. A complete character at
        // the end stays.
        if (*c != '\0') {
            size_t lead = length;
            while (lead > 0 && ((unsigned char)buffer[lead - 1] & 0xC0) == 0x80) {
                lead--;
            }
            if (lead > 0 && ((unsigned char)buffer[lead - 1] & 0xC0) == 0xC0) {
                unsigned char first = (unsigned char)buffer[lead - 1];
                size_t expected = (first & 0xE0) == 0xC0 ? 2 : (first & 0xF0) == 0xE0 ? 3 : (first & 0xF8) == 0xF0 ? 4 : 1;
                if (length - (lead - 1) < expected) {
                    length = lead - 1;
                }
            }
        }
        while (length > 0 && buffer[length - 1] == ' ') {
            length--;
        }
    }
    buffer[length] = '\0';
}

// Appends `text` to the growing buffer, keeping it NUL-terminated. Returns 0, or a negative error.
static int fluxo_append(char **buffer, size_t *length, size_t *capacity, const char *text, size_t count) {
    if (*length + count + 1 > *capacity) {
        size_t needed = *length + count + 1;
        size_t grown = *capacity > 0 ? *capacity * 2 : 256;
        char *larger = realloc(*buffer, grown > needed ? grown : needed);
        if (larger == NULL) {
            return AVERROR(ENOMEM);
        }
        *buffer = larger;
        *capacity = grown > needed ? grown : needed;
    }
    memcpy(*buffer + *length, text, count);
    *length += count;
    (*buffer)[*length] = '\0';
    return 0;
}

// The WebVTT tags kept from SubRip and WebVTT text (others are dropped, their text kept).
static int fluxo_vtt_tag(const char *tag, size_t length, char *normalized) {
    // tag points at '<', length includes '<' and '>'.
    if (length == 3 || length == 4) {
        int closing = tag[1] == '/';
        char name = tag[closing ? 2 : 1];
        if (name >= 'A' && name <= 'Z') {
            name = (char)(name - 'A' + 'a');
        }
        if ((size_t)(closing ? 4 : 3) == length && (name == 'i' || name == 'b' || name == 'u')) {
            snprintf(normalized, 5, closing ? "</%c>" : "<%c>", name);
            return 1;
        }
    }
    return 0;
}

// The WebVTT cue text of a text subtitle packet, or NULL when it has none (an empty or drawing-only event).
// SubRip and WebVTT keep <i>, <b> and <u>; ASS / SSA override blocks are removed except italics and bold.
static char *fluxo_subtitle_text(enum AVCodecID codec_id, const uint8_t *data, int size) {
    if (data == NULL || size <= 0) {
        return NULL;
    }
    const char *text = (const char *)data;
    size_t length = (size_t)size;
    if (codec_id == AV_CODEC_ID_MOV_TEXT) {
        // 3GPP timed text: a 16-bit length, then UTF-8 text (style boxes follow and are ignored).
        if (size < 2) {
            return NULL;
        }
        size_t declared = ((size_t)data[0] << 8) | data[1];
        text += 2;
        length = declared < (size_t)size - 2 ? declared : (size_t)size - 2;
    } else if (codec_id == AV_CODEC_ID_ASS || codec_id == AV_CODEC_ID_SSA) {
        // Matroska ASS events: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        int commas = 0;
        size_t i = 0;
        while (i < length && commas < 8) {
            if (text[i] == ',') {
                commas++;
            }
            i++;
        }
        if (commas < 8) {
            // Not the Matroska layout: take the text as it is.
            i = 0;
        }
        text += i;
        length -= i;
    }

    int is_ass = codec_id == AV_CODEC_ID_ASS || codec_id == AV_CODEC_ID_SSA;
    int keeps_entities = codec_id == AV_CODEC_ID_WEBVTT;
    char *out = NULL;
    size_t out_length = 0;
    size_t capacity = 0;
    int italic = 0;
    int bold = 0;
    int drawing = 0;
    int pending_newline = 0;
    int ret = 0;

    for (size_t i = 0; i < length && ret == 0; i++) {
        char c = text[i];
        if (c == '\0') {
            break;
        }
        if (is_ass && c == '{') {
            // An override block: {\i1}, {\b0}, {\p1} (drawing), {\an8}, ...
            size_t end = i + 1;
            while (end < length && text[end] != '}') {
                end++;
            }
            for (size_t j = i + 1; j + 1 < end; j++) {
                if (text[j] != '\\') {
                    continue;
                }
                char tag = text[j + 1];
                char value = j + 2 < end ? text[j + 2] : '\0';
                if ((tag == 'i' || tag == 'b') && (value == '0' || value == '1')) {
                    int *state = tag == 'i' ? &italic : &bold;
                    if (*state != (value == '1') && !drawing) {
                        *state = value == '1';
                        const char *html = tag == 'i' ? (*state ? "<i>" : "</i>") : (*state ? "<b>" : "</b>");
                        ret = fluxo_append(&out, &out_length, &capacity, html, strlen(html));
                    }
                } else if (tag == 'p' && value >= '0' && value <= '9') {
                    drawing = value != '0';
                }
            }
            i = end;
            continue;
        }
        if (drawing) {
            continue;
        }
        if (is_ass && c == '\\' && i + 1 < length && (text[i + 1] == 'N' || text[i + 1] == 'n' || text[i + 1] == 'h')) {
            if (text[i + 1] == 'h') {
                ret = fluxo_append(&out, &out_length, &capacity, " ", 1);
            } else {
                pending_newline = out_length > 0;
            }
            i++;
            continue;
        }
        if (!is_ass && c == '{' && i + 1 < length && text[i + 1] == '\\') {
            // SubRip position tags ({\an8}).
            while (i < length && text[i] != '}') {
                i++;
            }
            continue;
        }
        if (c == '\r') {
            continue;
        }
        if (c == '\n') {
            pending_newline = out_length > 0;
            continue;
        }
        if (pending_newline) {
            // One line break at most: an empty line would end the cue.
            ret = fluxo_append(&out, &out_length, &capacity, "\n", 1);
            pending_newline = 0;
            if (ret < 0) {
                break;
            }
        }
        if (c == '<' && !is_ass) {
            size_t end = i + 1;
            while (end < length && end - i < 64 && text[end] != '>' && text[end] != '<') {
                end++;
            }
            if (end < length && text[end] == '>') {
                char normalized[5];
                if (fluxo_vtt_tag(text + i, end - i + 1, normalized)) {
                    ret = fluxo_append(&out, &out_length, &capacity, normalized, strlen(normalized));
                } else if (keeps_entities) {
                    // WebVTT input: its other tags (<c.yellow>, <v Name>, timestamps) are valid as they are.
                    ret = fluxo_append(&out, &out_length, &capacity, text + i, end - i + 1);
                }
                // Other SubRip tags (<font color=...>) are dropped.
                i = end;
                continue;
            }
            ret = fluxo_append(&out, &out_length, &capacity, "&lt;", 4);
            continue;
        }
        if (c == '<') {
            ret = fluxo_append(&out, &out_length, &capacity, "&lt;", 4);
        } else if (c == '>' && !keeps_entities) {
            ret = fluxo_append(&out, &out_length, &capacity, "&gt;", 4);
        } else if (c == '&' && !keeps_entities) {
            ret = fluxo_append(&out, &out_length, &capacity, "&amp;", 5);
        } else {
            ret = fluxo_append(&out, &out_length, &capacity, &c, 1);
        }
    }
    if (ret == 0 && italic) {
        ret = fluxo_append(&out, &out_length, &capacity, "</i>", 4);
    }
    if (ret == 0 && bold) {
        ret = fluxo_append(&out, &out_length, &capacity, "</b>", 4);
    }
    // Trailing spaces only.
    while (ret == 0 && out_length > 0 && (out[out_length - 1] == ' ' || out[out_length - 1] == '\t')) {
        out[--out_length] = '\0';
    }
    if (ret < 0 || out_length == 0) {
        free(out);
        return NULL;
    }
    return out;
}

static void fluxo_rendition_drop_cue(FluxoRendition *rendition, int index) {
    free(rendition->cues[index].text);
    memmove(rendition->cues + index, rendition->cues + index + 1, sizeof(FluxoCue) * (size_t)(rendition->cue_count - index - 1));
    rendition->cue_count--;
}

// Queues the cue of a subtitle packet (output time base, already adjusted) for the next segments.
static int fluxo_rendition_add_cue(FluxoRendition *rendition, const AVPacket *packet, const AVStream *in_stream) {
    int64_t start = fluxo_packet_time(packet, in_stream);
    if (start == AV_NOPTS_VALUE) {
        return 0;
    }
    int64_t duration = packet->duration > 0 ? av_rescale_q(packet->duration, in_stream->time_base, AV_TIME_BASE_Q) : 0;
    if (duration <= 0) {
        duration = FLUXO_DEFAULT_CUE_DURATION;
    }
    char *text = fluxo_subtitle_text(rendition->codec_id, packet->data, packet->size);
    if (text == NULL) {
        return 0;
    }
    // The same cue read again (an on-demand input read over the same span after a seek or a reopen).
    for (int i = rendition->cue_count - 1; i >= 0 && rendition->cues[i].start >= start; i--) {
        if (rendition->cues[i].start == start && rendition->cues[i].end == start + duration && strcmp(rendition->cues[i].text, text) == 0) {
            free(text);
            return 0;
        }
    }
    if (rendition->cue_count == FLUXO_MAX_PENDING_CUES) {
        fluxo_rendition_drop_cue(rendition, 0);
    }
    if (rendition->cue_count == rendition->cue_capacity) {
        int capacity = rendition->cue_capacity > 0 ? rendition->cue_capacity * 2 : 32;
        FluxoCue *cues = realloc(rendition->cues, sizeof(FluxoCue) * (size_t)capacity);
        if (cues == NULL) {
            free(text);
            return AVERROR(ENOMEM);
        }
        rendition->cues = cues;
        rendition->cue_capacity = capacity;
    }
    // Kept in start order (demuxers deliver them in order, except around a reconnection).
    int index = rendition->cue_count;
    while (index > 0 && rendition->cues[index - 1].start > start) {
        index--;
    }
    memmove(rendition->cues + index + 1, rendition->cues + index, sizeof(FluxoCue) * (size_t)(rendition->cue_count - index));
    rendition->cues[index] = (FluxoCue){ .start = start, .end = start + duration, .text = text };
    rendition->cue_count++;
    return 0;
}

static void fluxo_vtt_time(int64_t time, char *buffer, size_t size) {
    if (time < 0) {
        time = 0;
    }
    int64_t milliseconds = time / 1000;
    snprintf(buffer, size, "%02lld:%02lld:%02lld.%03lld", (long long)(milliseconds / 3600000), (long long)(milliseconds / 60000 % 60),
             (long long)(milliseconds / 1000 % 60), (long long)(milliseconds % 1000));
}

// The extension of a rendition's segments.
static const char *fluxo_rendition_extension(const FluxoRendition *rendition) {
    if (rendition->type == FluxoRenditionSubtitles) {
        return "vtt";
    }
    return rendition->fragmented ? "m4s" : "ts";
}

static void fluxo_rendition_segment_path(const FluxoRendition *rendition, int64_t sequence, int temporary, char *buffer, size_t size) {
    snprintf(buffer, size, "%s-%06lld.%s%s", rendition->base_path, (long long)sequence, fluxo_rendition_extension(rendition),
             temporary ? ".tmp" : "");
}

// Writes the WebVTT segment `sequence` covering [start, end) of the output timeline (the last segment also
// takes the cues after it), then forgets the cues that end within it. Returns its size or a negative error.
static int64_t fluxo_rendition_write_vtt(FluxoHLS *hls, FluxoRendition *rendition, int64_t sequence, int64_t start, int64_t end, int last) {
    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
    fluxo_rendition_segment_path(rendition, sequence, 0, final_path, sizeof(final_path));
    FILE *file = fopen(temporary, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    // The cue times are output times; the MPEG-TS segments carry them shifted by the muxing delay.
    fprintf(file, "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:%lld,LOCAL:00:00:00.000\n\n", (long long)hls->mpegts_time_zero);
    for (int i = 0; i < rendition->cue_count; i++) {
        const FluxoCue *cue = &rendition->cues[i];
        if (cue->end <= start || (!last && cue->start >= end)) {
            continue;
        }
        char from[32];
        char to[32];
        fluxo_vtt_time(cue->start, from, sizeof(from));
        fluxo_vtt_time(cue->end, to, sizeof(to));
        fprintf(file, "%s --> %s\n%s\n\n", from, to, cue->text);
    }
    int64_t bytes = ftell(file);
    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(temporary);
        return AVERROR(EIO);
    }
    if (rename(temporary, final_path) != 0) {
        return AVERROR(errno);
    }
    // Cues that go on into the next segment are written again there (players drop the repeated cue).
    for (int i = rendition->cue_count - 1; i >= 0; i--) {
        if (last || rendition->cues[i].end <= end) {
            fluxo_rendition_drop_cue(rendition, i);
        }
    }
    return bytes > 0 ? bytes : 0;
}

static void fluxo_hls_free_renditions(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        fluxo_output_free(&rendition->output);
        for (int j = 0; j < rendition->cue_count; j++) {
            free(rendition->cues[j].text);
        }
        free(rendition->cues);
        free(rendition->base_path);
        free(rendition->playlist_path);
        free(rendition->playlist_tmp_path);
        free(rendition->init_path);
    }
    free(hls->renditions);
    hls->renditions = NULL;
    hls->rendition_count = 0;
    hls->audio_rendition_count = 0;
    hls->subtitle_rendition_count = 0;
}

static int fluxo_rendition_set_paths(FluxoHLS *hls, FluxoRendition *rendition, char kind, int number) {
    size_t length = strlen(hls->segment_prefix) + 16;
    rendition->base_path = malloc(length);
    rendition->playlist_path = malloc(length + 8);
    rendition->playlist_tmp_path = malloc(length + 12);
    rendition->init_path = malloc(length + 12);
    if (rendition->base_path == NULL || rendition->playlist_path == NULL || rendition->playlist_tmp_path == NULL ||
        rendition->init_path == NULL) {
        return AVERROR(ENOMEM);
    }
    snprintf(rendition->base_path, length, "%s-%c%d", hls->segment_prefix, kind, number);
    snprintf(rendition->playlist_path, length + 8, "%s.m3u8", rendition->base_path);
    snprintf(rendition->playlist_tmp_path, length + 12, "%s.m3u8.tmp", rendition->base_path);
    snprintf(rendition->init_path, length + 12, "%s-init.mp4", rendition->base_path);
    const char *slash = strrchr(rendition->base_path, '/');
    rendition->base_name = slash != NULL ? slash + 1 : rendition->base_path;
    return 0;
}

// Fills the name (unique in its group), language and flags of a rendition from its source stream.
static void fluxo_rendition_describe(FluxoHLS *hls, FluxoRendition *rendition, const AVStream *stream, int number) {
    const AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    fluxo_language_tag(language != NULL ? language->value : NULL, rendition->language, sizeof(rendition->language));
    rendition->is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
    rendition->forced = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
    rendition->hearing_impaired = (stream->disposition & (AV_DISPOSITION_HEARING_IMPAIRED | AV_DISPOSITION_CAPTIONS)) != 0;
    rendition->visual_impaired = (stream->disposition & (AV_DISPOSITION_VISUAL_IMPAIRED | AV_DISPOSITION_DESCRIPTIONS)) != 0;
    rendition->channels = stream->codecpar->ch_layout.nb_channels;

    // The title of the track, else its language tag, else its number: the app shows the language in the
    // user's own language when the name is only the tag or a number.
    char base[96];
    fluxo_attribute_text(title != NULL ? title->value : NULL, base, sizeof(base));
    if (base[0] == '\0') {
        snprintf(base, sizeof(base), "%s", rendition->language[0] != '\0' ? rendition->language : "");
    }
    if (base[0] == '\0') {
        snprintf(base, sizeof(base), "%d", number);
    }
    snprintf(rendition->name, sizeof(rendition->name), "%s", base);
    for (int copy = 2; copy < 100; copy++) {
        int taken = 0;
        for (int i = 0; i < hls->rendition_count; i++) {
            const FluxoRendition *other = &hls->renditions[i];
            if (other != rendition && other->type == rendition->type && strcmp(other->name, rendition->name) == 0) {
                taken = 1;
                break;
            }
        }
        if (!taken) {
            break;
        }
        snprintf(rendition->name, sizeof(rendition->name), "%s %d", base, copy);
    }
}

// Decides the renditions from the streams of the input, before the main output is prepared: with two audio
// streams or more, the main output keeps only the default one. Returns 0 or a negative error.
static int fluxo_hls_plan_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    AVFormatContext *input = session->input;
    if (hls->master_path == NULL) {
        return 0;
    }
    // Audio streams are counted by their ordinal among every supported audio stream (what the outputs
    // select by); only those in a codec HLS players decode can be renditions.
    int audio_total = 0;
    int hls_audio_count = 0;
    int subtitle_count = 0;
    int default_audio = -1;
    int first_hls_audio = -1;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        if (fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            if (fluxo_is_hls_audio(input, i) && hls_audio_count < FLUXO_MAX_RENDITIONS) {
                if (first_hls_audio < 0) {
                    first_hls_audio = audio_total;
                }
                if (default_audio < 0 && (stream->disposition & AV_DISPOSITION_DEFAULT)) {
                    default_audio = audio_total;
                }
                hls_audio_count++;
            }
            audio_total++;
        } else if (fluxo_is_subtitle_source(stream)) {
            subtitle_count++;
        }
    }
    if (subtitle_count > FLUXO_MAX_RENDITIONS) {
        subtitle_count = FLUXO_MAX_RENDITIONS;
    }
    if (default_audio < 0) {
        default_audio = first_hls_audio;
    }
    // Two playable audio tracks or more: a rendition each. Otherwise the audio stays as it was (every audio
    // stream in the main playlist).
    int audio_renditions = hls_audio_count > 1 ? hls_audio_count : 0;
    if (audio_renditions == 0 && subtitle_count == 0) {
        return 0;
    }
    hls->renditions = calloc((size_t)(audio_renditions + subtitle_count), sizeof(FluxoRendition));
    if (hls->renditions == NULL) {
        return AVERROR(ENOMEM);
    }

    int audio_ordinal = 0;
    int audio_renditions_made = 0;
    int subtitle_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int is_subtitle = fluxo_is_subtitle_source(stream);
        int takes_audio = is_audio && audio_renditions > 0 && audio_renditions_made < audio_renditions && fluxo_is_hls_audio(input, i);
        if ((is_audio && !takes_audio) || (is_subtitle && subtitle_ordinal >= subtitle_count) || (!is_audio && !is_subtitle)) {
            audio_ordinal += is_audio;
            continue;
        }
        FluxoRendition *rendition = &hls->renditions[hls->rendition_count++];
        rendition->type = is_audio ? FluxoRenditionAudio : FluxoRenditionSubtitles;
        rendition->ordinal = is_audio ? audio_ordinal : subtitle_ordinal;
        rendition->input_index = (int)i;
        rendition->codec_id = fluxo_stream_parameters(input, i)->codec_id;
        rendition->output.video_index = -1;
        int number = is_audio ? audio_ordinal + 1 : subtitle_ordinal + 1;
        fluxo_rendition_describe(hls, rendition, stream, number);
        // Converted audio has its own channel count (at most 5.1).
        rendition->channels = fluxo_stream_parameters(input, i)->ch_layout.nb_channels;
        if (is_audio) {
            rendition->muxed = audio_ordinal == default_audio;
            rendition->output.exclude_video = 1;
            rendition->output.audio_selection = audio_ordinal + 1;
            hls->audio_rendition_count++;
            audio_renditions_made++;
            audio_ordinal++;
        } else {
            hls->subtitle_rendition_count++;
            subtitle_ordinal++;
        }
        if (!rendition->muxed) {
            int ret = fluxo_rendition_set_paths(hls, rendition, is_audio ? 'a' : 's', number - 1);
            if (ret < 0) {
                return ret;
            }
        }
    }
    if (audio_renditions > 0) {
        // The main media playlist carries the video and the default audio track only.
        hls->output.audio_selection = default_audio + 1;
    }
    return 0;
}

// Prepares the muxers of the audio renditions (their segments are opened with the main ones).
static int fluxo_hls_prepare_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio || rendition->muxed) {
            continue;
        }
        rendition->fragmented = hls->fragmented;
        rendition->moov_flushed = 0;
        int ret = fluxo_output_prepare(&rendition->output, session->input, rendition->fragmented ? "mp4" : "mpegts", NULL);
        if (ret < 0) {
            return ret;
        }
        if (rendition->fragmented) {
            rendition->output.context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
            rendition->output.convert_adts = 1;
        } else {
            fluxo_hls_align_muxer(hls, rendition->output.context);
        }
    }
    return 0;
}

static int fluxo_hls_write_rendition_headers(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->output.context == NULL) {
            continue;
        }
        int ret = fluxo_output_write_header(&rendition->output, rendition->fragmented);
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

static void fluxo_write_media_attributes(FILE *file, const FluxoRendition *rendition) {
    if (rendition->language[0] != '\0') {
        fprintf(file, ",LANGUAGE=\"%s\"", rendition->language);
    }
}

// Looks for ATSC A/53 caption data ("GA94" user data, type 3: cc_data) in a video packet: an H.264 / HEVC SEI
// (registered ITU-T T.35) or MPEG-2 user data. Compressed data almost never contains these five bytes by chance.
static int fluxo_packet_has_closed_captions(const AVPacket *packet) {
    static const uint8_t marker[] = {'G', 'A', '9', '4', 0x03};
    return packet->data != NULL && packet->size >= (int)sizeof(marker)
        && memmem(packet->data, (size_t)packet->size, marker, sizeof(marker)) != NULL;
}

// Writes the master playlist: one variant (the main media playlist), its audio renditions and subtitles.
// Written with the first segment, once its video shows whether the stream carries closed captions.
// The RFC 6381 name of an H.264 stream ("avc1.PPCCLL") from its SPS (avcC or Annex B extradata). Returns 0
// when the stream does not carry one.
static int fluxo_avc_codec_name(const AVCodecParameters *codecpar, char *buffer, size_t size) {
    const uint8_t *data = codecpar->extradata;
    int length = codecpar->extradata_size;
    if (data == NULL || length < 4) {
        return 0;
    }
    if (data[0] == 1) {
        // avcC: version, profile, constraint flags, level.
        snprintf(buffer, size, "avc1.%02X%02X%02X", data[1], data[2], data[3]);
        return 1;
    }
    for (int i = 0; i + 6 < length; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 && (data[i + 3] & 0x1F) == 7) {
            snprintf(buffer, size, "avc1.%02X%02X%02X", data[i + 4], data[i + 5], data[i + 6]);
            return 1;
        }
    }
    return 0;
}

// The RFC 6381 name of an audio codec, or NULL when it is not one this engine names exactly.
static const char *fluxo_audio_codec_name(enum AVCodecID codec_id, int profile) {
    switch (codec_id) {
    case AV_CODEC_ID_AAC:
        if (profile == AV_PROFILE_AAC_HE) {
            return "mp4a.40.5";
        }
        if (profile == AV_PROFILE_AAC_HE_V2) {
            return "mp4a.40.29";
        }
        return profile == AV_PROFILE_AAC_LOW || profile == AV_PROFILE_UNKNOWN ? "mp4a.40.2" : NULL;
    case AV_CODEC_ID_AC3:
        return "ac-3";
    case AV_CODEC_ID_EAC3:
        return "ec-3";
    case AV_CODEC_ID_MP3:
        return "mp4a.40.34";
    default:
        return NULL;
    }
}

// Adds `name` to the comma-separated list `buffer` once. Returns 0 when it does not fit.
static int fluxo_codecs_add(char *buffer, size_t size, const char *name) {
    size_t used = strlen(buffer);
    size_t name_length = strlen(name);
    for (const char *at = strstr(buffer, name); at != NULL; at = strstr(at + 1, name)) {
        if ((at == buffer || at[-1] == ',') && (at[name_length] == ',' || at[name_length] == '\0')) {
            return 1;
        }
    }
    if (used + (used > 0 ? 1 : 0) + name_length + 1 > size) {
        return 0;
    }
    if (used > 0) {
        buffer[used++] = ',';
    }
    memcpy(buffer + used, name, name_length + 1);
    return 1;
}

// The CODECS attribute of the variant: the video and every audio rendition. Returns 0 (and no attribute is
// written) when one of them cannot be named exactly: a partial or wrong list is worse than none, since the
// player takes it as the complete list of what it must decode.
static int fluxo_hls_codecs(FluxoRemuxSession *session, char *buffer, size_t size) {
    FluxoHLS *hls = &session->hls;
    buffer[0] = '\0';
    AVFormatContext *output = hls->output.context;
    if (output == NULL) {
        return 0;
    }
    for (unsigned int i = 0; i < output->nb_streams; i++) {
        const AVCodecParameters *codecpar = output->streams[i]->codecpar;
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            char video[32];
            if (codecpar->codec_id != AV_CODEC_ID_H264 || !fluxo_avc_codec_name(codecpar, video, sizeof(video)) ||
                !fluxo_codecs_add(buffer, size, video)) {
                return 0;
            }
        } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            const char *audio = fluxo_audio_codec_name(codecpar->codec_id, codecpar->profile);
            if (audio == NULL || !fluxo_codecs_add(buffer, size, audio)) {
                return 0;
            }
        }
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio) {
            continue;
        }
        int profile = AV_PROFILE_UNKNOWN;
        if (rendition->input_index >= 0 && (unsigned int)rendition->input_index < session->input->nb_streams) {
            profile = fluxo_stream_parameters(session->input, (unsigned int)rendition->input_index)->profile;
        }
        const char *audio = fluxo_audio_codec_name(rendition->codec_id, profile);
        if (audio == NULL || !fluxo_codecs_add(buffer, size, audio)) {
            return 0;
        }
    }
    return buffer[0] != '\0';
}

static int fluxo_hls_write_master(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count == 0) {
        return 0;
    }
    FILE *file = fopen(hls->master_tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int has_audio_group = hls->audio_rendition_count > 0;
    int has_subtitles = hls->subtitle_rendition_count > 0;
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:4\n");
    if (hls->output.video_index >= 0) {
        fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio) {
            continue;
        }
        fprintf(file, "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"%s\"", rendition->name);
        fluxo_write_media_attributes(file, rendition);
        fprintf(file, ",DEFAULT=%s,AUTOSELECT=YES", rendition->muxed ? "YES" : "NO");
        if (rendition->channels > 0) {
            fprintf(file, ",CHANNELS=\"%d\"", rendition->channels);
        }
        if (rendition->visual_impaired) {
            fprintf(file, ",CHARACTERISTICS=\"public.accessibility.describes-video\"");
        }
        if (!rendition->muxed) {
            fprintf(file, ",URI=\"%s.m3u8\"", rendition->base_name);
        }
        fprintf(file, "\n");
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionSubtitles) {
            continue;
        }
        fprintf(file, "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"%s\"", rendition->name);
        fluxo_write_media_attributes(file, rendition);
        // Subtitles are never on by default: the system turns them on (accessibility settings, a foreign
        // language) and shows forced ones with their audio.
        fprintf(file, ",DEFAULT=NO,AUTOSELECT=YES,FORCED=%s", rendition->forced ? "YES" : "NO");
        if (rendition->hearing_impaired) {
            fprintf(file, ",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\"");
        }
        fprintf(file, ",URI=\"%s.m3u8\"\n", rendition->base_name);
    }
    if (hls->closed_captions && hls->output.video_index >= 0) {
        fprintf(file, "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC\",DEFAULT=NO,AUTOSELECT=YES,INSTREAM-ID=\"CC1\"\n");
    }

    int64_t bandwidth = session->input->bit_rate > 0 ? session->input->bit_rate : 4000000;
    fprintf(file, "#EXT-X-STREAM-INF:BANDWIDTH=%lld", (long long)bandwidth);
    if (hls->output.video_index >= 0) {
        const AVCodecParameters *video = hls->output.context->streams[hls->output.video_index]->codecpar;
        if (video->width > 0 && video->height > 0) {
            fprintf(file, ",RESOLUTION=%dx%d", video->width, video->height);
        }
    }
    char codecs[192];
    if (fluxo_hls_codecs(session, codecs, sizeof(codecs))) {
        fprintf(file, ",CODECS=\"%s\"", codecs);
    }
    if (has_audio_group) {
        fprintf(file, ",AUDIO=\"audio\"");
    }
    if (has_subtitles) {
        fprintf(file, ",SUBTITLES=\"subs\"");
    }
    if (hls->output.video_index >= 0) {
        // Without the attribute AVPlayer offers a "CC" option even when the video has no captions.
        fprintf(file, hls->closed_captions ? ",CLOSED-CAPTIONS=\"cc\"" : ",CLOSED-CAPTIONS=NONE");
    }
    fprintf(file, "\n%s.m3u8\n", hls->segment_base_name);

    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(hls->master_tmp_path);
        return AVERROR(EIO);
    }
    if (rename(hls->master_tmp_path, hls->master_path) != 0) {
        return AVERROR(errno);
    }
    hls->master_written = 1;
    return 0;
}

// Finds the sources of the renditions in a reconnected input. A rendition whose stream is gone stays in
// the master playlist (it cannot be removed from a playlist the player has read) and gets no new media.
static void fluxo_hls_remap_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        rendition->input_index = fluxo_rendition_find_source(rendition, session->input);
        if (rendition->output.context != NULL) {
            fluxo_output_map_input(&rendition->output, session->input);
        }
    }
}

// Opens audio segment `sequence` of every audio rendition (next to the main one). `resend_headers`: the muxer
// already wrote a segment, and this one must start with PAT/PMT too.
static int fluxo_hls_open_rendition_segments(FluxoHLS *hls, int64_t sequence, int resend_headers) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->output.context == NULL) {
            continue;
        }
        char path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 1, path, sizeof(path));
        int ret = avio_open(&rendition->output.context->pb, path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            return ret;
        }
        if (resend_headers && !rendition->fragmented) {
            av_opt_set(rendition->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
        }
    }
    return 0;
}

// Closes audio segment `sequence` of the renditions, keeping (publish) or deleting it with the main one.
// Returns the bytes kept, or a negative error.
static int64_t fluxo_hls_close_rendition_segments(FluxoHLS *hls, int64_t sequence, int flush, int publish) {
    int64_t total = 0;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        AVFormatContext *context = rendition->output.context;
        if (context == NULL || context->pb == NULL) {
            continue;
        }
        if (flush && rendition->output.header_written) {
            int ret = fluxo_output_flush(&rendition->output, rendition->fragmented, rendition->init_path, &rendition->init_written,
                                         &rendition->moov_flushed);
            if (ret < 0 && publish) {
                avio_closep(&context->pb);
                char temporary[PATH_MAX];
                fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
                unlink(temporary);
                return ret;
            }
        }
        avio_flush(context->pb);
        int64_t bytes = avio_tell(context->pb);
        avio_closep(&context->pb);
        char temporary[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
        if (!publish) {
            unlink(temporary);
            continue;
        }
        char final_path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 0, final_path, sizeof(final_path));
        if (rename(temporary, final_path) != 0) {
            return AVERROR(errno);
        }
        total += bytes > 0 ? bytes : 0;
    }
    return total;
}

// Writes the WebVTT segments `sequence` of the segment being finished, [start, end) of the output timeline.
static int64_t fluxo_hls_write_subtitle_segments(FluxoHLS *hls, int64_t sequence, int64_t start, int64_t end, int last) {
    int64_t total = 0;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionSubtitles) {
            continue;
        }
        int64_t bytes = fluxo_rendition_write_vtt(hls, rendition, sequence, start, end, last);
        if (bytes < 0) {
            return bytes;
        }
        total += bytes;
    }
    return total;
}

static void fluxo_hls_delete_rendition_segments(const FluxoHLS *hls, int64_t sequence) {
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        char path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 0, path, sizeof(path));
        unlink(path);
    }
}

// Copies a packet (output time base, already adjusted) to the renditions that take it.
static int fluxo_hls_write_renditions(FluxoHLS *hls, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type == FluxoRenditionSubtitles) {
            if (packet->stream_index == rendition->input_index) {
                int ret = fluxo_rendition_add_cue(rendition, packet, in_stream);
                if (ret < 0) {
                    return ret;
                }
            }
            continue;
        }
        if (rendition->output.context == NULL) {
            continue;
        }
        int ret = fluxo_output_prepare_packet(&rendition->output, packet, in_stream, scratch);
        if (ret < 0) {
            return ret;
        }
        if (ret > 0) {
            ret = fluxo_output_commit(&rendition->output, scratch);
            if (ret < 0) {
                return ret;
            }
        }
    }
    return 0;
}

// True when input stream `index` is the source of a subtitle rendition.
static int fluxo_hls_is_subtitle_source(const FluxoHLS *hls, int index) {
    for (int i = 0; i < hls->rendition_count; i++) {
        if (hls->renditions[i].type == FluxoRenditionSubtitles && hls->renditions[i].input_index == index) {
            return 1;
        }
    }
    return 0;
}

// Forgets the subtitle cues waiting for their segments.
static void fluxo_hls_clear_cues(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        for (int j = 0; j < rendition->cue_count; j++) {
            free(rendition->cues[j].text);
        }
        rendition->cue_count = 0;
    }
}

static int fluxo_hls_open_segment(FluxoHLS *hls) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, hls->next_sequence, 1, path, sizeof(path));
    int ret = avio_open(&hls->output.context->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        return ret;
    }
    if (!hls->fragmented && (hls->segments_written > 0 || hls->count > 0)) {
        // Every segment must start with PAT/PMT so that it can be decoded on its own.
        av_opt_set(hls->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
    }
    hls->segment_open = 1;
    ret = fluxo_hls_open_rendition_segments(hls, hls->next_sequence, hls->segments_written > 0 || hls->count > 0);
    if (ret < 0) {
        return ret;
    }
    hls->segment_start_time = AV_NOPTS_VALUE;
    hls->segment_cut_on_audio = 0;
    hls->last_reference_time = AV_NOPTS_VALUE;
    hls->segment_wallclock_ms = fluxo_wallclock_ms();
    return 0;
}

// Closes the current segment file, publishes it and rewrites the playlist.
// `flush` drains the muxer first (not needed after av_write_trailer).
static int fluxo_hls_finish_segment(FluxoRemuxSession *session, int64_t end_time, int flush, int ended) {
    FluxoHLS *hls = &session->hls;
    if (!hls->segment_open) {
        return ended ? fluxo_hls_write_playlist(hls, 1) : 0;
    }
    AVFormatContext *context = hls->output.context;
    if (flush) {
        int ret = fluxo_hls_flush(hls);
        if (ret < 0) {
            return ret;
        }
    }
    avio_flush(context->pb);
    int64_t bytes = avio_tell(context->pb);
    avio_closep(&context->pb);
    hls->segment_open = 0;

    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_hls_segment_path(hls, hls->next_sequence, 1, temporary, sizeof(temporary));
    fluxo_hls_segment_path(hls, hls->next_sequence, 0, final_path, sizeof(final_path));

    double duration = 0;
    if (hls->segment_start_time != AV_NOPTS_VALUE && end_time != AV_NOPTS_VALUE && end_time > hls->segment_start_time) {
        duration = (double)(end_time - hls->segment_start_time) / AV_TIME_BASE;
    }
    if (bytes <= 0 || duration < 0.05) {
        // Nothing playable (e.g. cancelled right after a cut).
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, hls->next_sequence, flush, 0);
        return ended ? fluxo_hls_write_playlist(hls, 1) : 0;
    }
    if (rename(temporary, final_path) != 0) {
        return AVERROR(errno);
    }
    // The renditions' segments of the same span, under the same sequence number.
    int64_t rendition_bytes = fluxo_hls_close_rendition_segments(hls, hls->next_sequence, flush, 1);
    if (rendition_bytes < 0) {
        return (int)rendition_bytes;
    }
    int64_t subtitle_bytes = fluxo_hls_write_subtitle_segments(hls, hls->next_sequence, hls->segment_start_time, end_time, ended);
    if (subtitle_bytes < 0) {
        return (int)subtitle_bytes;
    }
    bytes += rendition_bytes + subtitle_bytes;

    if (hls->count == hls->capacity) {
        int capacity = hls->capacity > 0 ? hls->capacity * 2 : 64;
        FluxoSegment *segments = realloc(hls->segments, sizeof(FluxoSegment) * (size_t)capacity);
        if (segments == NULL) {
            return AVERROR(ENOMEM);
        }
        hls->segments = segments;
        hls->capacity = capacity;
    }
    FluxoSegment *segment = &hls->segments[hls->count++];
    segment->sequence = hls->next_sequence++;
    segment->duration = duration;
    segment->bytes = bytes;
    segment->wallclock_ms = hls->segment_wallclock_ms;
    segment->discontinuity = hls->segment_discontinuity;
    hls->segment_discontinuity = 0;
    hls->window_duration += duration;
    hls->window_bytes += bytes;
    hls->segments_written++;

    // EXTINF rounded to the nearest integer must not exceed the target duration, and the target
    // should not change once published. Inputs are cut on key frames, so segments follow the GOP of
    // the stream: the first segment (written before the playlist is first published) seeds the
    // target with 50% headroom so that ordinary GOP jitter does not change it later. A longer
    // segment still raises it, because the EXTINF rule takes precedence. It never decreases.
    if (hls->segments_written == 1) {
        int seeded = (int)ceil(duration * 1.5);
        if (seeded > hls->target_duration) {
            hls->target_duration = seeded;
        }
    }
    int rounded = (int)lround(duration);
    if (rounded > hls->target_duration) {
        hls->target_duration = rounded;
    }

    fluxo_hls_prune(hls);
    int ret = fluxo_hls_write_playlist(hls, ended);
    if (ret < 0) {
        return ret;
    }
    if (!hls->master_written && hls->rendition_count > 0) {
        // Before the first SegmentWritten event: the player opens the master playlist when it gets it.
        ret = fluxo_hls_write_master(session);
        if (ret < 0) {
            return ret;
        }
    }
    // A segment is the proof that the (re)connection works.
    session->reconnect_attempt = 0;
    // (The window may have been pruned: `segment` no longer points at this segment.)
    session->event_segment_index = hls->next_sequence - 1;
    if (!session->is_live) {
        pthread_mutex_lock(&session->vod_lock);
        session->vod_available = hls->next_sequence;
        session->vod_init_ready = hls->init_written || !hls->fragmented;
        pthread_mutex_unlock(&session->vod_lock);
    }
    fluxo_emit(session, FluxoRemuxEventSegmentWritten, 0, NULL);
    return 0;
}

static int fluxo_hls_open(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    int ret = fluxo_hls_plan_renditions(session);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_prepare_output(session);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_prepare_renditions(session);
    if (ret < 0) {
        return ret;
    }
    hls->reference_stream = hls->output.video_index >= 0 ? hls->output.video_index : 0;
    hls->target_duration = (int)ceil(hls->segment_duration);

    ret = fluxo_hls_open_segment(hls);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_write_header(hls);
    if (ret < 0) {
        return ret;
    }
    // The master playlist is written with the first segment (fluxo_hls_finish_segment).
    return fluxo_hls_write_rendition_headers(hls);
}

static int fluxo_hls_write_main(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoHLS *hls = &session->hls;
    // Converted video whose encoder is refused (the app in the background, Picture in Picture) gives no packets:
    // the audio cuts the segments meanwhile, so that it keeps playing.
    int audio_cuts = hls->output.video_index >= 0 && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                     fluxo_streams_video_stalled(&session->streams);
    if (audio_cuts) {
        hls->output.wait_keyframe = 0;
    }
    int ret = fluxo_output_prepare_packet(&hls->output, packet, in_stream, scratch);
    if (ret <= 0) {
        return ret;
    }

    if (scratch->stream_index == hls->reference_stream || audio_cuts) {
        int64_t time = fluxo_packet_time(scratch, hls->output.context->streams[scratch->stream_index]);
        if (time != AV_NOPTS_VALUE) {
            if (hls->segment_start_time == AV_NOPTS_VALUE) {
                hls->segment_start_time = time;
            } else {
                int key = hls->output.video_index >= 0 && scratch->stream_index == hls->output.video_index && (scratch->flags & AV_PKT_FLAG_KEY);
                int cut_point = hls->output.video_index < 0 || key || audio_cuts;
                int64_t elapsed = time - hls->segment_start_time;
                // The tolerance is for key frames placed a little early; audio cuts exactly at the duration.
                int64_t tolerance = key ? FLUXO_SEGMENT_CUT_TOLERANCE : 0;
                int due = elapsed >= (int64_t)(hls->segment_duration * AV_TIME_BASE) - tolerance ||
                          (key && hls->segment_cut_on_audio && elapsed > 0);
                if (cut_point && due) {
                    ret = fluxo_hls_finish_segment(session, time, 1, 0);
                    if (ret >= 0) {
                        ret = fluxo_hls_open_segment(hls);
                    }
                    if (ret < 0) {
                        av_packet_unref(scratch);
                        return ret;
                    }
                    hls->segment_start_time = time;
                    hls->segment_cut_on_audio = audio_cuts;
                }
            }
            if (hls->last_reference_time == AV_NOPTS_VALUE || time > hls->last_reference_time) {
                hls->last_reference_time = time;
            }
        }
    }
    return fluxo_output_commit(&hls->output, scratch);
}

// Writes a packet to the main media playlist (cutting its segments) and to the renditions.
static int fluxo_hls_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count > 0 && !hls->master_written && !hls->closed_captions && hls->output.video_index >= 0
        && packet->stream_index >= 0 && (unsigned int)packet->stream_index < hls->output.stream_map_size
        && hls->output.stream_map[packet->stream_index] == hls->output.video_index) {
        hls->closed_captions = fluxo_packet_has_closed_captions(packet);
    }
    int ret = fluxo_hls_write_main(session, packet, in_stream, scratch);
    if (ret < 0 || session->hls.rendition_count == 0 || !session->hls.output.header_written) {
        return ret;
    }
    return fluxo_hls_write_renditions(&session->hls, packet, in_stream, scratch);
}

// Ends the current segment early, e.g. before a reconnection, and marks the next one as discontinuous.
static int fluxo_hls_break(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (!hls->output.header_written) {
        return 0;
    }
    int ret = 0;
    if (hls->segment_start_time != AV_NOPTS_VALUE) {
        ret = fluxo_hls_finish_segment(session, hls->last_reference_time, 1, 0);
        if (ret >= 0) {
            ret = fluxo_hls_open_segment(hls);
        }
    }
    hls->segment_discontinuity = 1;
    hls->output.wait_keyframe = hls->output.video_index >= 0;
    return ret;
}

static void fluxo_hls_close(FluxoRemuxSession *session, int ended) {
    FluxoHLS *hls = &session->hls;
    if (hls->output.header_written) {
        // Drains the muxer into the current segment, which is then published with EXT-X-ENDLIST. A
        // fragmented MP4 muxer is flushed first, so that its moov (if not written yet) goes to the
        // initialization segment.
        if (hls->fragmented && hls->segment_open) {
            fluxo_hls_flush(hls);
        }
        av_write_trailer(hls->output.context);
        for (int i = 0; i < hls->rendition_count; i++) {
            FluxoRendition *rendition = &hls->renditions[i];
            if (rendition->output.header_written && rendition->output.context->pb != NULL) {
                if (rendition->fragmented) {
                    fluxo_output_flush(&rendition->output, 1, rendition->init_path, &rendition->init_written, &rendition->moov_flushed);
                }
                av_write_trailer(rendition->output.context);
            }
        }
        if (hls->segment_open) {
            fluxo_hls_finish_segment(session, hls->last_reference_time, 0, ended);
        } else if (ended) {
            fluxo_hls_write_playlist(hls, 1);
        }
    } else if (hls->segment_open && hls->output.context != NULL) {
        char temporary[PATH_MAX];
        avio_closep(&hls->output.context->pb);
        fluxo_hls_segment_path(hls, hls->next_sequence, 1, temporary, sizeof(temporary));
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, hls->next_sequence, 0, 0);
        hls->segment_open = 0;
    }
    fluxo_output_free(&hls->output);
    for (int i = 0; i < hls->rendition_count; i++) {
        fluxo_output_free(&hls->renditions[i].output);
    }
}

// MARK: - Recording

static void fluxo_recording_close(FluxoRemuxSession *session, int error_code, const char *message) {
    FluxoRecording *recording = &session->recording;
    if (recording->path == NULL) {
        return;
    }
    int ret = error_code;
    if (recording->output.header_written) {
        int trailer = av_write_trailer(recording->output.context);
        if (ret == 0 && trailer < 0) {
            ret = trailer;
        }
        avio_flush(recording->output.context->pb);
    }
    if (ret < 0) {
        char buffer[512];
        fluxo_format_error(buffer, sizeof(buffer), ret, message != NULL ? message : "Recording failed");
        fluxo_emit(session, FluxoRemuxEventRecordingFailed, ret, buffer);
    } else {
        fluxo_emit(session, FluxoRemuxEventRecordingStopped, 0, NULL);
    }
    fluxo_output_free(&recording->output);
    free(recording->path);
    recording->path = NULL;
    recording->active = 0;
}

static void fluxo_recording_open(FluxoRemuxSession *session, char *path) {
    FluxoRecording *recording = &session->recording;
    recording->path = path;
    recording->first_time = AV_NOPTS_VALUE;
    recording->last_time = AV_NOPTS_VALUE;

    int ret = fluxo_output_prepare(&recording->output, session->input, "mpegts", path);
    if (ret >= 0) {
        ret = avio_open(&recording->output.context->pb, path, AVIO_FLAG_WRITE);
    }
    if (ret >= 0) {
        ret = avformat_write_header(recording->output.context, NULL);
        if (ret >= 0) {
            recording->output.header_written = 1;
        }
    }
    if (ret < 0) {
        fluxo_recording_close(session, ret, "Unable to start the recording");
        return;
    }
    recording->active = 1;
    fluxo_emit(session, FluxoRemuxEventRecordingStarted, 0, NULL);
}

static int fluxo_recording_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoRecording *recording = &session->recording;
    int ret = fluxo_output_prepare_packet(&recording->output, packet, in_stream, scratch);
    if (ret <= 0) {
        return ret;
    }
    int64_t time = fluxo_packet_time(scratch, recording->output.context->streams[scratch->stream_index]);
    if (time != AV_NOPTS_VALUE) {
        if (recording->first_time == AV_NOPTS_VALUE) {
            recording->first_time = time;
        }
        if (recording->last_time == AV_NOPTS_VALUE || time > recording->last_time) {
            recording->last_time = time;
        }
    }
    return fluxo_output_commit(&recording->output, scratch);
}

// Moves the queued (never opened) recording path to the discarded list. Caller holds request_lock.
static void fluxo_discard_pending_recording_locked(FluxoRemuxSession *session) {
    char *path = session->pending_recording_path;
    session->pending_recording_path = NULL;
    if (path == NULL) {
        return;
    }
    FluxoDiscardedRecording *node = malloc(sizeof(FluxoDiscardedRecording));
    if (node == NULL) {
        // Out of memory: the request is dropped without an event (the caller's own teardown still runs).
        free(path);
        return;
    }
    node->path = path;
    node->next = NULL;
    // Appended, so that the events keep the order of the requests.
    FluxoDiscardedRecording **tail = &session->discarded_recordings;
    while (*tail != NULL) {
        tail = &(*tail)->next;
    }
    *tail = node;
}

static void fluxo_free_discarded_recordings(FluxoDiscardedRecording *list) {
    while (list != NULL) {
        FluxoDiscardedRecording *next = list->next;
        free(list->path);
        free(list);
        list = next;
    }
}

// Reports (RecordingStopped, nothing written) and frees recordings that were never opened.
static void fluxo_report_discarded_recordings(FluxoRemuxSession *session, FluxoDiscardedRecording *list) {
    for (FluxoDiscardedRecording *node = list; node != NULL; node = node->next) {
        fluxo_emit_with_path(session, FluxoRemuxEventRecordingStopped, 0, NULL, node->path);
    }
    fluxo_free_discarded_recordings(list);
}

// Applies pending recording requests. Starting needs an open input; otherwise the request stays queued.
static void fluxo_process_requests(FluxoRemuxSession *session) {
    if (!atomic_load(&session->request_pending)) {
        return;
    }
    pthread_mutex_lock(&session->request_lock);
    char *path = NULL;
    int stop = session->pending_recording_stop;
    session->pending_recording_stop = 0;
    if (session->input != NULL) {
        path = session->pending_recording_path;
        session->pending_recording_path = NULL;
    }
    FluxoDiscardedRecording *discarded = session->discarded_recordings;
    session->discarded_recordings = NULL;
    atomic_store(&session->request_pending, session->pending_recording_path != NULL);
    pthread_mutex_unlock(&session->request_lock);

    fluxo_report_discarded_recordings(session, discarded);
    if ((stop || path != NULL) && session->recording.path != NULL) {
        fluxo_recording_close(session, 0, NULL);
    }
    if (path != NULL) {
        fluxo_recording_open(session, path);
    }
}

// Called when the engine thread ends: every recording request still queued gets its terminal event.
static void fluxo_drain_requests(FluxoRemuxSession *session) {
    pthread_mutex_lock(&session->request_lock);
    if (session->pending_recording_path != NULL) {
        fluxo_discard_pending_recording_locked(session);
    }
    session->pending_recording_stop = 0;
    FluxoDiscardedRecording *discarded = session->discarded_recordings;
    session->discarded_recordings = NULL;
    atomic_store(&session->request_pending, false);
    pthread_mutex_unlock(&session->request_lock);

    fluxo_report_discarded_recordings(session, discarded);
}

// MARK: - Packet loop

// Applies the session offset and handles input timestamp discontinuities (e.g. MPEG-TS wrap,
// encoder restarts or a reconnection).
static void fluxo_adjust_timestamps(FluxoRemuxSession *session, AVPacket *packet, const AVStream *in_stream) {
    if (packet->dts != AV_NOPTS_VALUE) {
        int64_t raw = av_rescale_q(packet->dts, in_stream->time_base, AV_TIME_BASE_Q);
        if (session->rebase_pending) {
            // Continue right after the last packet written before the input changed.
            int64_t target = session->last_input_dts == AV_NOPTS_VALUE ? FLUXO_TIMESTAMP_BASE : session->last_input_dts + FLUXO_RECONNECT_GAP;
            session->timestamp_offset = target - raw;
            session->last_input_dts = AV_NOPTS_VALUE;
            session->rebase_pending = 0;
        }
        int64_t dts = raw + session->timestamp_offset;
        int discontinuous_input = (session->input->iformat->flags & AVFMT_TS_DISCONT) != 0;
        if (discontinuous_input && session->last_input_dts != AV_NOPTS_VALUE) {
            int64_t delta = dts - session->last_input_dts;
            if (delta > FLUXO_DISCONTINUITY_THRESHOLD || delta < -FLUXO_DISCONTINUITY_THRESHOLD) {
                session->timestamp_offset -= delta;
                dts -= delta;
            }
        }
        if (session->last_input_dts == AV_NOPTS_VALUE || dts > session->last_input_dts) {
            session->last_input_dts = dts;
        }
    }

    int64_t offset = av_rescale_q(session->timestamp_offset, AV_TIME_BASE_Q, in_stream->time_base);
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts += offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts += offset;
    }
}

// fluxo_adjust_timestamps for FluxoStreams.adjust: applied to the packets as the input gives them.
static void fluxo_adjust_input_packet(void *opaque, AVPacket *packet, const AVStream *in_stream) {
    fluxo_adjust_timestamps(opaque, packet, in_stream);
}

static void fluxo_vod_wait(FluxoRemuxSession *session, uint64_t wakeups, int64_t timeout_us);

// Longest sleep of a paused on-demand reader. Every request wakes it at once (fluxo_vod_signal): this only bounds
// the sleep should a wake-up ever be missed. While it waits, the engine thread costs nothing (it used to wake up
// four times a second for a whole movie once it was read ahead, or read to its end).
#define FLUXO_VOD_IDLE_WAIT_US (5 * 1000000LL)

// Reads the input until it ends, fails or the session is cancelled. Returns the read error
// (AVERROR_EOF at the end) or the output error, in which case `output_failed` is set.
static int fluxo_run_loop(FluxoRemuxSession *session) {
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    if (packet == NULL || scratch == NULL) {
        av_packet_free(&packet);
        av_packet_free(&scratch);
        session->output_failed = 1;
        return AVERROR(ENOMEM);
    }

    int ret = 0;
    // On-demand input without a plan: segments are listed as they are written, as fast as the input
    // allows (positions are seekable only once read); over the disk budget, reading pauses once it is
    // read_ahead seconds of segments ahead of the latest one the player requested.
    int64_t read_ahead_segments = (int64_t)ceil(session->read_ahead / session->hls.segment_duration);
    // Timestamps are moved to the session's timeline as the input gives the packets, before any is converted.
    session->streams.adjust = fluxo_adjust_input_packet;
    session->streams.adjust_opaque = session;
    while (!fluxo_is_cancelled(session)) {
        fluxo_process_requests(session);

        if (!session->is_live) {
            pthread_mutex_lock(&session->vod_lock);
            int64_t ahead = session->vod_available - 1 - session->vod_requested;
            int over_budget = session->vod_budget_bytes > 0 && session->hls.window_bytes > session->vod_budget_bytes;
            session->vod_paused = over_budget && (session->vod_paused ? ahead > read_ahead_segments / 2 : ahead > read_ahead_segments);
            int paused = session->vod_paused;
            uint64_t wakeups = session->vod_wakeups;
            pthread_mutex_unlock(&session->vod_lock);
            if (paused) {
                fluxo_vod_wait(session, wakeups, FLUXO_VOD_IDLE_WAIT_US);
                continue;
            }
        }

        ret = fluxo_streams_read(&session->streams, packet);
        if (ret == AVERROR(EAGAIN)) {
            ret = 0;
            continue;
        }
        if (ret < 0) {
            break;
        }
        if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= session->input->nb_streams) {
            av_packet_unref(packet);
            continue;
        }

        AVStream *in_stream = session->input->streams[packet->stream_index];
        ret = fluxo_hls_write(session, packet, in_stream, scratch);
        if (ret < 0) {
            av_packet_unref(packet);
            session->output_failed = 1;
            break;
        }
        if (session->recording.active) {
            int recording_ret = fluxo_recording_write(session, packet, in_stream, scratch);
            if (recording_ret < 0) {
                // A full disk stops the recording, not the stream.
                fluxo_recording_close(session, recording_ret, "Recording stopped");
            }
        }
        av_packet_unref(packet);
    }

    session->streams.adjust = NULL;
    session->streams.adjust_opaque = NULL;
    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

// Sleeps up to `duration_us`, waking up early when the session is cancelled.
static void fluxo_wait(FluxoRemuxSession *session, int64_t duration_us) {
    while (duration_us > 0 && !fluxo_is_cancelled(session)) {
        int64_t step = duration_us < 100000 ? duration_us : 100000;
        usleep((useconds_t)step);
        duration_us -= step;
        fluxo_process_requests(session);
    }
}

// Reconnects a live input. Returns 0 once packets can flow again, a negative value to give up.
static int fluxo_reconnect(FluxoRemuxSession *session, int last_error) {
    int ret = fluxo_hls_break(session);
    if (ret < 0) {
        session->output_failed = 1;
        return ret;
    }
    fluxo_close_input(session);

    while (!fluxo_is_cancelled(session)) {
        session->reconnect_attempt++;
        if (session->max_reconnect_attempts > 0 && session->reconnect_attempt > session->max_reconnect_attempts) {
            return last_error < 0 ? last_error : AVERROR(ECONNRESET);
        }
        fluxo_set_state(session, FluxoRemuxStateReconnecting, last_error, NULL);

        // 0.5s, 1s, 2s, 4s, 8s, 8s, ...
        int shift = session->reconnect_attempt - 1 < 4 ? session->reconnect_attempt - 1 : 4;
        int64_t delay = (AV_TIME_BASE / 2) << shift;
        fluxo_wait(session, delay < FLUXO_MAX_RECONNECT_DELAY_US ? delay : FLUXO_MAX_RECONNECT_DELAY_US);
        if (fluxo_is_cancelled(session)) {
            break;
        }

        ret = fluxo_open_input(session);
        if (ret < 0) {
            last_error = ret;
            continue;
        }
        ret = fluxo_output_map_input(&session->hls.output, session->input);
        if (ret <= 0) {
            // The stream layout changed (e.g. a different codec): the playlist cannot continue.
            session->output_failed = 1;
            return ret < 0 ? ret : AVERROR_STREAM_NOT_FOUND;
        }
        fluxo_hls_remap_renditions(session);
        if (session->recording.path != NULL) {
            ret = fluxo_output_map_input(&session->recording.output, session->input);
            if (ret <= 0) {
                fluxo_recording_close(session, ret < 0 ? ret : AVERROR_STREAM_NOT_FOUND, "Recording stopped");
            } else {
                session->recording.output.wait_keyframe = session->recording.output.video_index >= 0;
            }
        }
        session->rebase_pending = 1;
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        return 0;
    }
    return AVERROR_EXIT;
}

// MARK: - On-demand inputs

// Wakes the engine thread (a segment request, a recording request, a cancellation). Call with vod_lock held.
static void fluxo_vod_signal_locked(FluxoRemuxSession *session) {
    session->vod_wakeups++;
    pthread_cond_broadcast(&session->vod_cond);
}

static void fluxo_vod_signal(FluxoRemuxSession *session) {
    pthread_mutex_lock(&session->vod_lock);
    fluxo_vod_signal_locked(session);
    pthread_mutex_unlock(&session->vod_lock);
}

// Sleeps while reading is paused: until the next wake-up after the one numbered `wakeups` (read under vod_lock
// with the decision to pause, so a request that came in between is not missed), a cancellation, or `timeout_us`.
static void fluxo_vod_wait(FluxoRemuxSession *session, uint64_t wakeups, int64_t timeout_us) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_us / 1000000);
    deadline.tv_nsec += (long)(timeout_us % 1000000) * 1000;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&session->vod_lock);
    while (session->vod_wakeups == wakeups && session->vod_reposition < 0 && !fluxo_is_cancelled(session)) {
        if (pthread_cond_timedwait(&session->vod_cond, &session->vod_lock, &deadline) == ETIMEDOUT) {
            break;
        }
    }
    pthread_mutex_unlock(&session->vod_lock);
}

static int fluxo_compare_times(const void *a, const void *b) {
    int64_t left = *(const int64_t *)a;
    int64_t right = *(const int64_t *)b;
    return left < right ? -1 : left > right;
}

// Time of `packet` (input timeline, AV_TIME_BASE units) used to place it in a segment. Key frames of the
// reference video use the same clock as the index the plan was made from.
static int64_t fluxo_vod_packet_time(const FluxoPlan *plan, const AVPacket *packet, const AVStream *stream, int key_clock) {
    int64_t ts;
    if (key_clock && plan->key_uses_dts) {
        ts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    } else {
        ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    }
    return ts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q);
}

static int fluxo_vod_input_is_seekable(const AVFormatContext *input) {
    // Demuxers without an AVIOContext of their own (e.g. HLS) seek through their own requests.
    return input->pb == NULL || (input->pb->seekable & AVIO_SEEKABLE_NORMAL) != 0;
}

// Plans the VOD playlist of an on-demand input: from the key frame index when it covers the input (MP4,
// Matroska with Cues, AVI), otherwise one segment every segment_duration. Returns 1 when planned, 0 when
// the input has no reliable duration (it is then remuxed from start to end, see fluxo_run_loop), a
// negative error on allocation failure.
static int fluxo_vod_plan(FluxoRemuxSession *session) {
    AVFormatContext *input = session->input;
    FluxoPlan *plan = &session->plan;
    // A duration estimated from the bit rate (an MPEG-TS file served without byte ranges) can be minutes off.
    if (input->duration == AV_NOPTS_VALUE || input->duration <= 0 || input->duration_estimation_method == AVFMT_DURATION_FROM_BITRATE) {
        return 0;
    }
    int video = -1;
    int audio = -1;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *stream = input->streams[i];
        if (!fluxo_is_stream_supported(stream)) {
            continue;
        }
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video < 0) {
            video = (int)i;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio < 0) {
            audio = (int)i;
        }
    }
    if (video < 0 && audio < 0) {
        return 0;
    }
    plan->has_video = video >= 0;
    plan->reference_input_stream = video >= 0 ? video : audio;
    const char *format = input->iformat->name;
    // Converted video gets its key frames at the planned times, by presentation time.
    plan->key_uses_dts = (strstr(format, "mov") != NULL || strstr(format, "avi") != NULL) &&
                         !(video >= 0 && fluxo_stream_is_converted(input, (unsigned int)video));

    int64_t start = input->start_time != AV_NOPTS_VALUE ? input->start_time : 0;
    int64_t end = start + input->duration;
    int64_t step = (int64_t)(session->hls.segment_duration * AV_TIME_BASE);

    int64_t *keys = NULL;
    int key_count = 0;
    if (video >= 0) {
        AVStream *stream = input->streams[video];
        int indexed = avformat_index_get_entries_count(stream);
        const AVIndexEntry *last_entry = indexed > 0 ? avformat_index_get_entry(stream, indexed - 1) : NULL;
        int64_t indexed_until = last_entry != NULL && last_entry->timestamp != AV_NOPTS_VALUE
            ? av_rescale_q(last_entry->timestamp, stream->time_base, AV_TIME_BASE_Q) : AV_NOPTS_VALUE;
        if ((indexed_until == AV_NOPTS_VALUE || indexed_until < end - FLUXO_VOD_INDEX_COVERAGE_GAP) && fluxo_vod_input_is_seekable(input)) {
            // Matroska reads its index (Cues) at the first seek (until then it lists the key frames it read while
            // probing, often one); this one goes back to the start.
            av_seek_frame(input, video, stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0, AVSEEK_FLAG_BACKWARD);
            fluxo_streams_reset(&session->streams);
        }
        int entries = avformat_index_get_entries_count(stream);
        if (entries > 0) {
            keys = malloc(sizeof(int64_t) * (size_t)entries);
            if (keys == NULL) {
                return AVERROR(ENOMEM);
            }
            for (int i = 0; i < entries; i++) {
                const AVIndexEntry *entry = avformat_index_get_entry(stream, i);
                if (entry != NULL && (entry->flags & AVINDEX_KEYFRAME) && entry->timestamp != AV_NOPTS_VALUE) {
                    keys[key_count++] = av_rescale_q(entry->timestamp, stream->time_base, AV_TIME_BASE_Q);
                }
            }
            qsort(keys, (size_t)key_count, sizeof(int64_t), fluxo_compare_times);
        }
    }
    // The index must reach both ends (some files index only their first minutes) and have no holes: a
    // demuxer without an index of its own (MPEG-TS) only lists the key frames it happened to read while
    // probing the start and the end of the file, which would plan a single segment for the whole movie.
    int exact = key_count >= 2 && keys[0] <= start + 10 * AV_TIME_BASE && keys[key_count - 1] >= end - FLUXO_VOD_INDEX_COVERAGE_GAP;
    for (int i = 1; exact && i < key_count; i++) {
        if (keys[i] - keys[i - 1] > FLUXO_VOD_INDEX_MAX_KEY_GAP) {
            exact = 0;
        }
    }

    int capacity = exact ? key_count + 1 : (int)(input->duration / (step > 0 ? step : AV_TIME_BASE)) + 3;
    plan->starts = malloc(sizeof(int64_t) * (size_t)(capacity + 1));
    if (plan->starts == NULL) {
        free(keys);
        return AVERROR(ENOMEM);
    }
    int count = 0;
    if (exact) {
        // Segments of at least the target duration, each starting on a key frame; a short tail joins the last one.
        plan->starts[count++] = keys[0];
        for (int i = 1; i < key_count; i++) {
            if (keys[i] - plan->starts[count - 1] >= step && keys[i] < end - step / 2 && keys[i] > plan->starts[count - 1]) {
                plan->starts[count++] = keys[i];
            }
        }
    } else {
        for (int64_t time = start; (count == 0 || time < end - step / 2) && count < capacity; time += step) {
            plan->starts[count++] = time;
        }
    }
    free(keys);
    if (end <= plan->starts[count - 1]) {
        end = plan->starts[count - 1] + step;
    }
    plan->starts[count] = end;
    plan->count = count;
    plan->exact = exact;
    plan->bytes = calloc((size_t)count, sizeof(int64_t));
    plan->blind = calloc((size_t)count, sizeof(uint8_t));
    plan->blind_count = 0;
    plan->independent = calloc((size_t)count, sizeof(uint8_t));
    if (plan->bytes == NULL || plan->blind == NULL || plan->independent == NULL) {
        return AVERROR(ENOMEM);
    }
    session->vod_end_segment = count - 1;
    fluxo_streams_set_key_times(&session->streams, plan->starts, plan->count);
    return 1;
}

static void fluxo_vod_plan_free(FluxoPlan *plan) {
    free(plan->starts);
    plan->starts = NULL;
    free(plan->bytes);
    plan->bytes = NULL;
    free(plan->blind);
    plan->blind = NULL;
    plan->blind_count = 0;
    free(plan->independent);
    plan->independent = NULL;
    plan->count = 0;
}

// Writes one complete VOD media playlist of the plan: the main one, or a rendition's (the same segments under
// other file names, `extension` "ts" for audio, "vtt" for subtitles).
static int fluxo_vod_write_media_playlist(FluxoRemuxSession *session, const char *path, const char *tmp_path, const char *base_name,
                                          const char *extension, const char *init_path, int is_main) {
    const FluxoPlan *plan = &session->plan;
    FILE *file = fopen(tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int target = 1;
    for (int i = 0; i < plan->count; i++) {
        int rounded = (int)ceil((double)(plan->starts[i + 1] - plan->starts[i]) / AV_TIME_BASE - 0.001);
        if (rounded > target) {
            target = rounded;
        }
    }
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:%d\n", init_path != NULL ? 7 : 3);
    fprintf(file, "#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n", target);
    if (session->start_time > 0) {
        // A resume: the player starts there (with the segment the engine produces first, see fluxo_vod_open).
        fprintf(file, "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES\n", (double)session->start_time / AV_TIME_BASE);
    }
    // Every segment the player seeks into starts with a key frame: the boundaries of an index are key frames, and
    // otherwise the first segment of a run starts with its pre-roll, and a segment cut inside a GOP is written again
    // when a seek asks for it (fluxo_remux_request_segment). Audio and subtitle segments always are. Without it,
    // AVPlayer loads the segment before the one it seeks into too, which costs a second seek of the input.
    fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    if (init_path != NULL) {
        const char *slash = strrchr(init_path, '/');
        fprintf(file, "#EXT-X-MAP:URI=\"%s\"\n", slash != NULL ? slash + 1 : init_path);
    }
    for (int i = 0; i < plan->count; i++) {
        fprintf(file, "#EXTINF:%.3f,\n%s-%06d.%s\n", (double)(plan->starts[i + 1] - plan->starts[i]) / AV_TIME_BASE, base_name, i, extension);
    }
    fprintf(file, "#EXT-X-ENDLIST\n");
    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(tmp_path);
        return AVERROR(EIO);
    }
    if (rename(tmp_path, path) != 0) {
        return AVERROR(errno);
    }
    return 0;
}

// Writes the complete VOD playlists, once, before playback starts: the renditions' first, then the main one.
// Segments are produced when requested. The master playlist follows with the first segment.
static int fluxo_vod_write_playlist(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        int ret = fluxo_vod_write_media_playlist(session, rendition->playlist_path, rendition->playlist_tmp_path, rendition->base_name,
                                                 fluxo_rendition_extension(rendition), rendition->fragmented ? rendition->init_path : NULL, 0);
        if (ret < 0) {
            return ret;
        }
    }
    return fluxo_vod_write_media_playlist(session, hls->playlist_path, hls->playlist_tmp_path, hls->segment_base_name,
                                          hls->segment_extension, hls->fragmented ? hls->init_path : NULL, 1);
}

static void fluxo_vod_drop_held(FluxoRemuxSession *session) {
    for (int i = 0; i < session->vod_held_count; i++) {
        av_packet_free(&session->vod_held[i].packet);
    }
    session->vod_held_count = 0;
}

static void fluxo_vod_drop_preroll(FluxoRemuxSession *session) {
    for (int i = 0; i < session->vod_preroll_count; i++) {
        av_packet_free(&session->vod_preroll[i].packet);
    }
    session->vod_preroll_count = 0;
}

// Forgets the packets of the GOP in memory and those still to replay (the input moved: they no longer lead to
// where it reads).
static void fluxo_vod_drop_gop(FluxoRemuxSession *session) {
    for (int i = 0; i < session->vod_kept_count; i++) {
        av_packet_free(&session->vod_kept[i].packet);
    }
    session->vod_kept_count = 0;
    session->vod_kept_bytes = 0;
    session->vod_kept_valid = 0;
    for (int i = session->vod_replay_next; i < session->vod_replay_count; i++) {
        av_packet_free(&session->vod_replay[i].packet);
    }
    session->vod_replay_count = 0;
    session->vod_replay_next = 0;
    session->vod_read_time = AV_NOPTS_VALUE;
}

// Empties the GOP in memory; `valid`: whether it is kept from now on (from a key frame).
static void fluxo_vod_clear_kept(FluxoRemuxSession *session, int valid) {
    for (int i = 0; i < session->vod_kept_count; i++) {
        av_packet_free(&session->vod_kept[i].packet);
    }
    session->vod_kept_count = 0;
    session->vod_kept_bytes = 0;
    session->vod_kept_valid = valid;
}

// Appends `packet` (owned: freed when it is not kept) to the GOP in memory, within its limits.
static void fluxo_vod_keep(FluxoRemuxSession *session, AVPacket *packet, int64_t time) {
    if (!session->vod_kept_valid) {
        av_packet_free(&packet);
        return;
    }
    if (session->vod_kept_count >= FLUXO_VOD_MAX_PREROLL_PACKETS || session->vod_kept_bytes + packet->size > FLUXO_VOD_GOP_MEMORY_BYTES) {
        // Too long to keep: until the next key frame, a seek here reads it again from the input.
        av_packet_free(&packet);
        fluxo_vod_clear_kept(session, 0);
        return;
    }
    if (session->vod_kept_count == session->vod_kept_capacity) {
        int capacity = session->vod_kept_capacity > 0 ? session->vod_kept_capacity * 2 : 256;
        FluxoHeldPacket *kept = realloc(session->vod_kept, sizeof(FluxoHeldPacket) * (size_t)capacity);
        if (kept == NULL) {
            av_packet_free(&packet);
            fluxo_vod_clear_kept(session, 0);
            return;
        }
        session->vod_kept = kept;
        session->vod_kept_capacity = capacity;
    }
    session->vod_kept[session->vod_kept_count].packet = packet;
    session->vod_kept[session->vod_kept_count].time = time;
    session->vod_kept_count++;
    session->vod_kept_bytes += packet->size;
}

// Keeps a reference to `packet`, just read (or replayed), in the GOP in memory: a key frame of the reference video
// starts it over. Plans without an index only.
static void fluxo_vod_remember(FluxoRemuxSession *session, const AVPacket *packet) {
    const FluxoPlan *plan = &session->plan;
    if (plan->exact || !plan->has_video) {
        return;
    }
    AVStream *stream = session->input->streams[packet->stream_index];
    int reference = packet->stream_index == plan->reference_input_stream;
    int64_t time = fluxo_vod_packet_time(plan, packet, stream, 0);
    if (reference && time != AV_NOPTS_VALUE) {
        session->vod_read_time = time;
    }
    if (reference && (packet->flags & AV_PKT_FLAG_KEY)) {
        fluxo_vod_clear_kept(session, time != AV_NOPTS_VALUE);
    }
    if (!session->vod_kept_valid) {
        return;
    }
    AVPacket *copy = av_packet_clone(packet);
    if (copy == NULL) {
        fluxo_vod_clear_kept(session, 0);
        return;
    }
    fluxo_vod_keep(session, copy, time);
}

// A seek to segment `index` of a plan without an index, when the GOP in memory starts at or before it and the input
// was read to about there: the reader goes back to the GOP's key frame by replaying its packets (no network). The
// packets that were still to replay go back into the GOP first (they lead to where the input is). Returns 1 when it
// replays, 0 when the input must seek.
static int fluxo_vod_replay(FluxoRemuxSession *session, int64_t index) {
    const FluxoPlan *plan = &session->plan;
    for (int i = session->vod_replay_next; i < session->vod_replay_count; i++) {
        fluxo_vod_keep(session, session->vod_replay[i].packet, session->vod_replay[i].time);
        session->vod_replay[i].packet = NULL;
    }
    session->vod_replay_count = 0;
    session->vod_replay_next = 0;
    if (plan->exact || !plan->has_video || index <= 0 || index >= plan->count || !session->vod_kept_valid || session->vod_kept_count == 0 ||
        session->vod_read_time == AV_NOPTS_VALUE) {
        return 0;
    }
    int64_t key = session->vod_kept[0].time;
    int64_t boundary = plan->starts[index];
    if (key == AV_NOPTS_VALUE || key > boundary + FLUXO_VOD_TIME_EPSILON || boundary > session->vod_read_time + FLUXO_VOD_READ_ON_TIME) {
        return 0;
    }
    // The GOP becomes the replay queue (each packet is remembered again as it is replayed).
    FluxoHeldPacket *replay = session->vod_replay;
    int replay_capacity = session->vod_replay_capacity;
    session->vod_replay = session->vod_kept;
    session->vod_replay_capacity = session->vod_kept_capacity;
    session->vod_replay_count = session->vod_kept_count;
    session->vod_replay_next = 0;
    session->vod_kept = replay;
    session->vod_kept_capacity = replay_capacity;
    session->vod_kept_count = 0;
    session->vod_kept_bytes = 0;
    session->vod_kept_valid = 0;
    return 1;
}

// Adds `packet` to the pre-roll. Returns 0, or a negative error on allocation failure.
static int fluxo_vod_add_preroll(FluxoRemuxSession *session, const AVPacket *packet, int64_t time) {
    if (session->vod_preroll_count >= FLUXO_VOD_MAX_PREROLL_PACKETS) {
        // A GOP longer than the pre-roll can hold: the segment starts as it did without one.
        fluxo_vod_drop_preroll(session);
        return 0;
    }
    if (session->vod_preroll_count == session->vod_preroll_capacity) {
        int capacity = session->vod_preroll_capacity > 0 ? session->vod_preroll_capacity * 2 : 256;
        FluxoHeldPacket *preroll = realloc(session->vod_preroll, sizeof(FluxoHeldPacket) * (size_t)capacity);
        if (preroll == NULL) {
            return AVERROR(ENOMEM);
        }
        session->vod_preroll = preroll;
        session->vod_preroll_capacity = capacity;
    }
    AVPacket *copy = av_packet_clone(packet);
    if (copy == NULL) {
        return AVERROR(ENOMEM);
    }
    session->vod_preroll[session->vod_preroll_count].packet = copy;
    session->vod_preroll[session->vod_preroll_count].time = time;
    session->vod_preroll_count++;
    return 0;
}

static int fluxo_vod_hold(FluxoRemuxSession *session, const AVPacket *packet, int64_t time) {
    if (session->vod_held_count == session->vod_held_capacity) {
        int capacity = session->vod_held_capacity > 0 ? session->vod_held_capacity * 2 : 64;
        FluxoHeldPacket *held = realloc(session->vod_held, sizeof(FluxoHeldPacket) * (size_t)capacity);
        if (held == NULL) {
            return AVERROR(ENOMEM);
        }
        session->vod_held = held;
        session->vod_held_capacity = capacity;
    }
    AVPacket *copy = av_packet_clone(packet);
    if (copy == NULL) {
        return AVERROR(ENOMEM);
    }
    session->vod_held[session->vod_held_count].packet = copy;
    session->vod_held[session->vod_held_count].time = time;
    session->vod_held_count++;
    return 0;
}

// Ends the current run: the partial segment is deleted and the muxer freed without a trailer (after a
// seek, an error or a cancellation).
static void fluxo_vod_abort_run(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (hls->segment_open && hls->output.context != NULL) {
        char temporary[PATH_MAX];
        avio_closep(&hls->output.context->pb);
        fluxo_hls_segment_path(hls, session->vod_segment, 1, temporary, sizeof(temporary));
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, session->vod_segment, 0, 0);
    }
    hls->segment_open = 0;
    fluxo_output_free(&hls->output);
    for (int i = 0; i < hls->rendition_count; i++) {
        fluxo_output_free(&hls->renditions[i].output);
    }
    hls->moov_flushed = 0;
    session->vod_writing = 0;
    fluxo_vod_drop_held(session);
    fluxo_vod_drop_preroll(session);
}

// Deletes the segments farthest from the player while the cache is over its budget. Kept: the two
// segments before the latest request and the read-ahead after it.
static void fluxo_vod_evict(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    FluxoPlan *plan = &session->plan;
    if (hls->max_window_bytes <= 0) {
        return;
    }
    pthread_mutex_lock(&session->vod_lock);
    while (session->vod_cached_bytes > hls->max_window_bytes) {
        int64_t requested = session->vod_requested;
        int64_t keep_from = requested - 2;
        int64_t keep_to = requested;
        int64_t horizon = plan->starts[requested] + (int64_t)(session->read_ahead * AV_TIME_BASE);
        while (keep_to + 1 < plan->count && plan->starts[keep_to + 1] <= horizon) {
            keep_to++;
        }
        keep_to++;
        int victim = -1;
        int64_t farthest = -1;
        for (int i = 0; i < plan->count; i++) {
            if (plan->bytes[i] <= 0 || (i >= keep_from && i <= keep_to)) {
                continue;
            }
            // Played segments go first: going back far is rarer than continuing.
            int64_t distance = i < requested ? (requested - i) * 2 : i - requested;
            if (distance > farthest) {
                farthest = distance;
                victim = i;
            }
        }
        if (victim < 0) {
            break;
        }
        fluxo_hls_delete_segment(hls, victim);
        session->vod_cached_bytes -= plan->bytes[victim];
        plan->bytes[victim] = 0;
        session->vod_segments_on_disk--;
    }
    pthread_mutex_unlock(&session->vod_lock);
}

// Opens the file of segment `index`, starting a new run (muxer) when none is open.
static int fluxo_vod_open_segment(FluxoRemuxSession *session, int64_t index) {
    FluxoHLS *hls = &session->hls;
    int new_run = hls->output.context == NULL;
    if (new_run) {
        int ret = fluxo_hls_prepare_output(session);
        if (ret >= 0) {
            ret = fluxo_hls_prepare_renditions(session);
        }
        if (ret < 0) {
            return ret;
        }
        // The plan decides the cuts and where a run starts (fluxo_vod_route).
        hls->output.wait_keyframe = 0;
    }
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, index, 1, path, sizeof(path));
    int ret = avio_open(&hls->output.context->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        return ret;
    }
    hls->segment_open = 1;
    session->vod_segment_independent = !session->plan.has_video;
    session->vod_segment_awaits_video = session->plan.has_video;
    // The audio renditions' segments of the same span, under the same number.
    ret = fluxo_hls_open_rendition_segments(hls, index, !new_run);
    if (ret < 0) {
        return ret;
    }
    if (new_run) {
        ret = fluxo_hls_write_header(hls);
        if (ret >= 0) {
            ret = fluxo_hls_write_rendition_headers(hls);
        }
        if (ret < 0) {
            return ret;
        }
        // Video packets before the first key frame of a run cannot be decoded.
        session->vod_need_key = session->plan.has_video;
    } else if (!hls->fragmented) {
        // Every segment must start with PAT/PMT so that it can be decoded on its own.
        av_opt_set(hls->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
    }
    session->vod_writing = 1;
    session->vod_segment_pictures = 0;
    return 0;
}

// Keeps track of the segments written without a picture while converted video had no encoder; once a segment has
// pictures again, deletes them (but the one the player asked for last and the one before, which it may be reading), so that the
// player gets them again with pictures when it asks. Called with vod_lock held, after segment `index` is published.
static void fluxo_vod_track_blind_locked(FluxoRemuxSession *session, int64_t index) {
    FluxoPlan *plan = &session->plan;
    if (plan->blind == NULL || !plan->has_video || !fluxo_stream_is_converted(session->input, (unsigned int)plan->reference_input_stream)) {
        return;
    }
    if (session->vod_segment_pictures == 0) {
        if (!plan->blind[index]) {
            plan->blind[index] = 1;
            plan->blind_count++;
        }
        return;
    }
    if (plan->blind[index]) {
        plan->blind[index] = 0;
        plan->blind_count--;
    }
    for (int i = 0; i < plan->count && plan->blind_count > 0; i++) {
        if (!plan->blind[i] || (i >= session->vod_requested - 1 && i <= session->vod_requested)) {
            continue;
        }
        plan->blind[i] = 0;
        plan->blind_count--;
        if (plan->bytes[i] > 0) {
            fluxo_hls_delete_segment(&session->hls, i);
            session->vod_cached_bytes -= plan->bytes[i];
            plan->bytes[i] = 0;
            session->vod_segments_on_disk--;
        }
    }
}

// Publishes the current segment: flushes it, renames it into place and reports it.
static int fluxo_vod_finish_segment(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    AVFormatContext *context = hls->output.context;
    int64_t index = session->vod_segment;
    int ret = fluxo_hls_flush(hls);
    if (ret < 0) {
        return ret;
    }
    avio_flush(context->pb);
    int64_t bytes = avio_tell(context->pb);
    ret = avio_closep(&context->pb);
    hls->segment_open = 0;
    session->vod_writing = 0;

    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_hls_segment_path(hls, index, 1, temporary, sizeof(temporary));
    fluxo_hls_segment_path(hls, index, 0, final_path, sizeof(final_path));
    if (ret < 0 || bytes <= 0) {
        // An error, or no packet reached it (the input ended, or had nothing between two cuts): nothing to publish.
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, index, 1, 0);
        return ret < 0 ? ret : 0;
    }
    if (rename(temporary, final_path) != 0) {
        fluxo_hls_close_rendition_segments(hls, index, 1, 0);
        return AVERROR(errno);
    }
    if (hls->rendition_count > 0) {
        // The renditions' segments are in place before the segment is reported (the player asks for them
        // at about the same time). Subtitles cover the planned span of the segment, output timeline.
        int64_t rendition_bytes = fluxo_hls_close_rendition_segments(hls, index, 1, 1);
        if (rendition_bytes < 0) {
            return (int)rendition_bytes;
        }
        const FluxoPlan *plan = &session->plan;
        int64_t subtitle_bytes = fluxo_hls_write_subtitle_segments(hls, index, plan->starts[index] + session->timestamp_offset,
                                                                   plan->starts[index + 1] + session->timestamp_offset,
                                                                   index == plan->count - 1);
        if (subtitle_bytes < 0) {
            return (int)subtitle_bytes;
        }
        bytes += rendition_bytes + subtitle_bytes;
        if (!hls->master_written) {
            // Before the first SegmentWritten event: the player opens the master playlist when it gets it.
            ret = fluxo_hls_write_master(session);
            if (ret < 0) {
                return ret;
            }
        }
    }

    pthread_mutex_lock(&session->vod_lock);
    session->plan.bytes[index] = bytes;
    session->plan.independent[index] = (uint8_t)session->vod_segment_independent;
    session->vod_cached_bytes += bytes;
    session->vod_segments_on_disk++;
    session->vod_init_ready = hls->init_written || !hls->fragmented;
    fluxo_vod_track_blind_locked(session, index);
    pthread_mutex_unlock(&session->vod_lock);

    hls->segments_written++;
    session->vod_recoveries = 0;
    session->vod_preroll_backoffs = 0;
    session->reconnect_attempt = 0;
    session->event_segment_index = index;
    fluxo_emit(session, FluxoRemuxEventSegmentWritten, 0, NULL);
    fluxo_vod_evict(session);
    return 0;
}

// Moves the reader from its segment to the next one: publishes the finished segment, then opens the next
// one if it is wanted and not on disk yet. A segment already on disk is read through without writing,
// unless the next missing one is far: then the reader seeks there.
static int fluxo_vod_cut(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    FluxoPlan *plan = &session->plan;
    if (session->vod_writing) {
        int ret = fluxo_vod_finish_segment(session);
        if (ret < 0) {
            return ret;
        }
    }
    int64_t next = session->vod_segment + 1;
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = next;
    int on_disk = next < plan->count && plan->bytes[next] > 0;
    int64_t missing = -1;
    if (on_disk) {
        for (int64_t i = next + 1; i < plan->count; i++) {
            if (plan->bytes[i] <= 0) {
                missing = i;
                break;
            }
        }
    }
    if (on_disk && missing > next && plan->starts[missing] - plan->starts[next] > FLUXO_VOD_READ_ON_TIME && session->vod_reposition < 0) {
        session->vod_reposition = missing;
    }
    pthread_mutex_unlock(&session->vod_lock);

    if (next >= plan->count) {
        return 0;
    }
    if (next >= session->vod_target && !on_disk) {
        return fluxo_vod_open_segment(session, next);
    }
    // Not written: the next written segment starts a new run, whose first fragment is placed by its own
    // timestamps (frag_discont), like after a seek.
    if (hls->output.context != NULL) {
        fluxo_vod_abort_run(session);
    }
    return 0;
}

// Writes `packet` (input timeline) to the current segment, or drops it while no segment is written.
static int fluxo_vod_write(FluxoRemuxSession *session, AVPacket *packet, AVPacket *scratch) {
    if (!session->vod_writing) {
        return 0;
    }
    AVStream *in_stream = session->input->streams[packet->stream_index];
    if (session->vod_need_key && packet->stream_index == session->plan.reference_input_stream && session->plan.has_video) {
        if (!(packet->flags & AV_PKT_FLAG_KEY)) {
            return 0;
        }
        session->vod_need_key = 0;
    }
    if (session->vod_segment_awaits_video && packet->stream_index == session->plan.reference_input_stream) {
        session->vod_segment_awaits_video = 0;
        session->vod_segment_independent = (packet->flags & AV_PKT_FLAG_KEY) != 0;
    }
    int64_t offset = av_rescale_q(session->timestamp_offset, AV_TIME_BASE_Q, in_stream->time_base);
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts += offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts += offset;
    }
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count > 0 && !hls->master_written && !hls->closed_captions && hls->output.video_index >= 0 &&
        (unsigned int)packet->stream_index < hls->output.stream_map_size &&
        hls->output.stream_map[packet->stream_index] == hls->output.video_index) {
        hls->closed_captions = fluxo_packet_has_closed_captions(packet);
    }
    int ret = fluxo_output_prepare_packet(&hls->output, packet, in_stream, scratch);
    if (ret > 0) {
        if (scratch->stream_index == hls->output.video_index) {
            session->vod_segment_pictures++;
        }
        ret = fluxo_output_commit(&hls->output, scratch);
    }
    if (ret >= 0 && hls->rendition_count > 0) {
        // Extra audio tracks and subtitles: packets the main output does not take.
        ret = fluxo_hls_write_renditions(hls, packet, in_stream, scratch);
    }
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts -= offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts -= offset;
    }
    return ret < 0 ? ret : 0;
}

// Places one input packet in the plan. A segment ends at the first key frame of the reference video at or
// after the start of the next segment. Packets at or after that start are held until that key frame
// arrives (they belong to the current segment if they come before it). When no key frame comes before the
// segment after next (a longer GOP than planned), the cut is made at the planned time instead.
static int fluxo_vod_route(FluxoRemuxSession *session, AVPacket *packet, AVPacket *scratch) {
    FluxoPlan *plan = &session->plan;
    AVStream *in_stream = session->input->streams[packet->stream_index];
    int reference = packet->stream_index == plan->reference_input_stream;
    int key = reference && (packet->flags & AV_PKT_FLAG_KEY);
    int64_t time = fluxo_vod_packet_time(plan, packet, in_stream, 0);
    int64_t key_time = key ? fluxo_vod_packet_time(plan, packet, in_stream, 1) : AV_NOPTS_VALUE;
    int ret;
    if (key && time != AV_NOPTS_VALUE) {
        int64_t interval = time - session->vod_last_key;
        if (session->vod_last_key != AV_NOPTS_VALUE && interval > 0 && interval <= FLUXO_VOD_INDEX_MAX_KEY_GAP && interval > session->vod_gop) {
            session->vod_gop = interval;
        }
        session->vod_last_key = time;
    }

    if (session->vod_check_seek && reference && time != AV_NOPTS_VALUE && session->vod_seek_position >= 0) {
        // A byte seek: where it landed tells how far off the estimate was.
        int64_t error = time - session->vod_seek_time;
        int64_t size = session->input->pb != NULL ? avio_size(session->input->pb) : -1;
        int64_t duration = session->input->duration;
        if ((error > FLUXO_VOD_BYTE_SEEK_LATE || error < -FLUXO_VOD_BYTE_SEEK_EARLY) && session->vod_seek_corrections < FLUXO_VOD_BYTE_SEEK_CORRECTIONS &&
            size > 0 && duration > 0) {
            double bytes_per_time = (double)size / (double)duration;
            // A late landing goes back a little more than the error, so that the next one is early (reading on is cheap).
            int64_t correction = error > 0 ? error + AV_TIME_BASE : error + AV_TIME_BASE * 2;
            int64_t position = session->vod_seek_position - (int64_t)(correction * bytes_per_time);
            if (position < 0) {
                position = 0;
            }
            if (position != session->vod_seek_position && av_seek_frame(session->input, -1, position, AVSEEK_FLAG_BYTE) >= 0) {
                FLUXO_TRACE("byte seek for %.2f s landed at %.2f s: again at byte %lld", session->vod_seek_time / 1e6, time / 1e6, (long long)position);
                fluxo_streams_reset(&session->streams);
                fluxo_vod_drop_gop(session);
                session->vod_seek_position = position;
                session->vod_seek_corrections++;
                return 0;
            }
        }
        FLUXO_TRACE("byte seek for %.2f s landed at %.2f s", session->vod_seek_time / 1e6, time / 1e6);
        session->vod_check_seek = 0;
        session->vod_seek_position = -1;
    }
    if (session->vod_check_seek && reference && time != AV_NOPTS_VALUE) {
        session->vod_check_seek = 0;
        int64_t target = plan->starts[session->vod_target];
        int64_t step = (int64_t)(session->hls.segment_duration * AV_TIME_BASE);
        if (time > target + 2 * step && session->vod_target > 0) {
            // Landed after the target: seek again from earlier, with a margin of the overshoot.
            int64_t earlier = target - (time - target) - step;
            if (earlier < plan->starts[0]) {
                earlier = plan->starts[0];
            }
            if (av_seek_frame(session->input, -1, earlier, AVSEEK_FLAG_BACKWARD) >= 0) {
                fluxo_streams_reset(&session->streams);
                fluxo_vod_drop_gop(session);
                FLUXO_TRACE("seek to segment %lld landed at %.2f s, after its start %.2f s: again from %.2f s", (long long)session->vod_target,
                            time / 1e6, target / 1e6, earlier / 1e6);
                return 0;
            }
        }
    }
    int64_t upcoming = session->vod_segment + 1;
    // (Only without an index: the boundaries of an index are key frames.)
    if (!plan->exact && plan->has_video && !session->vod_writing && session->vod_segment >= 0 && upcoming >= session->vod_target &&
        upcoming < plan->count && plan->bytes[upcoming] <= 0 && time != AV_NOPTS_VALUE) {
        // The reader writes nothing yet and the next segment starts a run: after a seek (the reader is in the
        // segment before the target), or after reading through segments already on disk.
        int64_t boundary = plan->starts[upcoming];
        if (time < boundary - FLUXO_VOD_TIME_EPSILON) {
            if (key) {
                // The latest key frame before the target segment so far: the pre-roll starts over from it.
                fluxo_vod_drop_preroll(session);
            }
            if (key || session->vod_preroll_count > 0) {
                ret = fluxo_vod_add_preroll(session, packet, time);
                if (ret < 0) {
                    return ret;
                }
            }
            return 0;
        }
        if (reference && !(key && key_time != AV_NOPTS_VALUE && key_time >= boundary - FLUXO_VOD_TIME_EPSILON)) {
            // The target segment starts inside a GOP.
            if (session->vod_preroll_count == 0 && session->vod_preroll_backoffs < FLUXO_VOD_MAX_PREROLL_BACKOFFS &&
                fluxo_vod_input_is_seekable(session->input)) {
                // No key frame was read before it: seek back further for one.
                session->vod_preroll_backoffs++;
                int64_t earlier = boundary - session->vod_preroll_backoffs * FLUXO_VOD_PREROLL_BACKOFF;
                if (earlier < plan->starts[0]) {
                    earlier = plan->starts[0];
                }
                FLUXO_TRACE("segment %lld starts inside a GOP at %.2f s, no key frame read: back to %.2f s", (long long)upcoming,
                            boundary / 1e6, earlier / 1e6);
                int64_t size = session->input->pb != NULL ? avio_size(session->input->pb) : -1;
                int seeked;
                if (size > 0 && session->input->duration > 0 && (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
                    // By byte position, like the seek itself (fluxo_vod_seek).
                    int64_t position = (int64_t)((double)(earlier - plan->starts[0]) / (double)session->input->duration * (double)size);
                    seeked = av_seek_frame(session->input, -1, position > 0 ? position : 0, AVSEEK_FLAG_BYTE) >= 0;
                } else {
                    seeked = av_seek_frame(session->input, -1, earlier, AVSEEK_FLAG_BACKWARD) >= 0;
                }
                if (seeked) {
                    fluxo_streams_reset(&session->streams);
                    fluxo_vod_drop_held(session);
                    fluxo_vod_drop_gop(session);
                    return 0;
                }
            }
            if (session->vod_preroll_count > 0) {
                // Open the target segment and start it with the pre-roll from its key frame: AVPlayer decodes from
                // there and shows the frames from the target on.
                FLUXO_TRACE("segment %lld starts inside a GOP at %.2f s: pre-roll of %d packets from the key frame at %.2f s",
                            (long long)upcoming, boundary / 1e6, session->vod_preroll_count, session->vod_preroll[0].time / 1e6);
                ret = fluxo_vod_cut(session);
                if (ret < 0) {
                    return ret;
                }
                if (session->vod_writing) {
                    // AVPlayer places an MPEG-TS segment by its first video frame, at the start the playlist gives the
                    // segment: frames from the key frame before it would shift the whole picture off the timeline by
                    // the length of the pre-roll. So the pre-roll's video frames before the segment are presented
                    // just before its start (they are decoded, then dropped by the seek, which lands at or after it)
                    // and its audio before the segment is left out.
                    // Squeezed into the last ticks before their segment's first own frame: decode times in decode order,
                    // just before the decode time of the video packet that opens the segment (later frames keep theirs,
                    // and the muxer drops a packet whose decode time goes back), presentation times in presentation order
                    // in the last ticks before the segment's start, so a seek to that start shows at most the last of
                    // them, the frame just before it. Decode times never go back from the end of the segment before
                    // either (it ends a frame before that packet), which plays into this one when it is on disk.
                    int video = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        const FluxoHeldPacket *held = &session->vod_preroll[i];
                        if (held->packet->stream_index == plan->reference_input_stream && held->time != AV_NOPTS_VALUE && held->time < boundary) {
                            video++;
                        }
                    }
                    int64_t *order = video > 0 ? malloc(sizeof(int64_t) * (size_t)video) : NULL;
                    if (video > 0 && order == NULL) {
                        return AVERROR(ENOMEM);
                    }
                    int count = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        const FluxoHeldPacket *held = &session->vod_preroll[i];
                        if (held->packet->stream_index == plan->reference_input_stream && held->time != AV_NOPTS_VALUE && held->time < boundary) {
                            order[count++] = held->time;
                        }
                    }
                    if (video > 0) {
                        qsort(order, (size_t)video, sizeof(int64_t), fluxo_compare_times);
                    }
                    int decoded;
                    AVStream *reference_stream = session->input->streams[plan->reference_input_stream];
                    int64_t start_ticks = av_rescale_q(boundary, AV_TIME_BASE_Q, reference_stream->time_base);
                    int64_t opening = packet->dts != AV_NOPTS_VALUE ? packet->dts : (packet->pts != AV_NOPTS_VALUE ? packet->pts : start_ticks);
                    int64_t base_dts = opening - video - 1;
                    int64_t base_pts = start_ticks - video;
                    decoded = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        AVPacket *held = session->vod_preroll[i].packet;
                        int64_t time = session->vod_preroll[i].time;
                        if (time != AV_NOPTS_VALUE && time < boundary) {
                            if (held->stream_index != plan->reference_input_stream) {
                                // The pre-roll's audio before the segment is left out.
                                continue;
                            }
                            int64_t *found = bsearch(&time, order, (size_t)video, sizeof(int64_t), fluxo_compare_times);
                            int rank = found != NULL ? (int)(found - order) : decoded;
                            held->dts = base_dts + decoded;
                            held->pts = base_pts + rank;
                            if (held->pts < held->dts) {
                                held->pts = held->dts;
                            }
                            decoded++;
                        }
                        ret = fluxo_vod_write(session, held, scratch);
                        if (ret < 0) {
                            free(order);
                            return ret;
                        }
                    }
                    free(order);
                    // Packets held at the start of the segment (audio read before this video packet) follow it.
                    for (int i = 0; i < session->vod_held_count; i++) {
                        ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                        if (ret < 0) {
                            return ret;
                        }
                    }
                }
                fluxo_vod_drop_preroll(session);
                fluxo_vod_drop_held(session);
                // The packet is placed against the boundaries of the target segment (below).
            }
        }
    }
    if (session->vod_segment < 0) {
        // Reading from the start: the first packet opens segment 0.
        ret = fluxo_vod_cut(session);
        if (ret < 0) {
            return ret;
        }
    }
    for (;;) {
        int64_t next = session->vod_segment + 1;
        if (next >= plan->count) {
            return fluxo_vod_write(session, packet, scratch);
        }
        int64_t boundary = plan->starts[next];
        int64_t following = next + 1 < plan->count ? plan->starts[next + 1] : INT64_MAX;
        if (!plan->has_video) {
            if (reference && time != AV_NOPTS_VALUE && time >= boundary - FLUXO_VOD_TIME_EPSILON) {
                ret = fluxo_vod_cut(session);
                if (ret < 0) {
                    return ret;
                }
                continue;
            }
            return fluxo_vod_write(session, packet, scratch);
        }
        if (key && key_time != AV_NOPTS_VALUE && key_time >= boundary - FLUXO_VOD_TIME_EPSILON) {
            for (int i = 0; i < session->vod_held_count; i++) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
            fluxo_vod_drop_held(session);
            // A pre-roll read for this segment is not needed: it starts with its own key frame.
            fluxo_vod_drop_preroll(session);
            ret = fluxo_vod_cut(session);
            if (ret < 0) {
                return ret;
            }
            return fluxo_vod_write(session, packet, scratch);
        }
        int pending = session->vod_held_count > 0 || (time != AV_NOPTS_VALUE && time >= boundary - FLUXO_VOD_TIME_EPSILON);
        if (!pending) {
            return fluxo_vod_write(session, packet, scratch);
        }
        // Converted video whose encoder is refused (the app in the background, Picture in Picture) gives no
        // packets: the audio cuts at the planned start meanwhile, so that it keeps playing.
        int audio_cuts = !reference && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && time != AV_NOPTS_VALUE &&
                         time >= boundary - FLUXO_VOD_TIME_EPSILON && fluxo_streams_video_stalled(&session->streams);
        // Without an index the cut is made at the planned time, key frame or not: the media of every segment then
        // starts where the playlist says, which is where AVPlayer places it (MPEG-TS media is placed by the playlist,
        // not by its timestamps: segments that start later or earlier than planned shift the picture off the
        // timeline). A seek into a segment that starts inside a GOP writes it again with a pre-roll.
        int overdue = (reference && time != AV_NOPTS_VALUE && time >= following - FLUXO_VOD_TIME_EPSILON) ||
                      session->vod_held_count >= FLUXO_VOD_MAX_HELD_PACKETS || audio_cuts ||
                      (!plan->exact && reference && time != AV_NOPTS_VALUE);
        if (!overdue) {
            return fluxo_vod_hold(session, packet, time);
        }
        // No key frame in the next segment: cut at its planned start.
        fluxo_vod_drop_preroll(session);
        int held = session->vod_held_count;
        for (int i = 0; i < held; i++) {
            if (session->vod_held[i].time == AV_NOPTS_VALUE || session->vod_held[i].time < boundary) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
        }
        ret = fluxo_vod_cut(session);
        if (ret < 0) {
            return ret;
        }
        for (int i = 0; i < held; i++) {
            if (session->vod_held[i].time != AV_NOPTS_VALUE && session->vod_held[i].time >= boundary) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
        }
        fluxo_vod_drop_held(session);
        // The packet is placed against the boundaries of the new segment.
    }
}

// Positions the reader at the start of segment `index`: seeks to the key frame at or before it, or (an
// input that cannot seek, e.g. a server without byte ranges) reads on to it, or reads again from the start.
static int fluxo_vod_seek(FluxoRemuxSession *session, int64_t index) {
    FluxoPlan *plan = &session->plan;
    fluxo_vod_abort_run(session);
    int64_t current = session->vod_segment;

    pthread_mutex_lock(&session->vod_lock);
    if (session->vod_regenerate == index && plan->bytes[index] > 0) {
        // On disk, but it does not start with a key frame: written again, with a pre-roll.
        fluxo_hls_delete_segment(&session->hls, index);
        session->vod_cached_bytes -= plan->bytes[index];
        session->vod_segments_on_disk--;
        plan->bytes[index] = 0;
        plan->independent[index] = 0;
    }
    session->vod_regenerate = -1;
    pthread_mutex_unlock(&session->vod_lock);

    if (fluxo_vod_replay(session, index)) {
        // From the key frame in memory: the segment starts with its pre-roll (fluxo_vod_route), and the reader
        // continues with the input where it is once the replayed packets are routed.
        fluxo_hls_clear_cues(&session->hls);
        pthread_mutex_lock(&session->vod_lock);
        session->vod_segment = index - 1;
        session->vod_target = index;
        session->vod_ended = 0;
        session->vod_paused = 0;
        pthread_mutex_unlock(&session->vod_lock);
        session->vod_need_key = plan->has_video;
        session->vod_preroll_backoffs = 0;
        session->vod_check_seek = 0;
        session->vod_seek_position = -1;
        session->vod_last_key = AV_NOPTS_VALUE;
        FLUXO_TRACE("seek to segment %lld (%.2f s) from segment %lld: replaying %d packets from the key frame at %.2f s", (long long)index,
                    plan->starts[index] / 1e6, (long long)current, session->vod_replay_count, session->vod_replay[0].time / 1e6);
        return 0;
    }
    // The input moves: the GOP in memory no longer leads to where it reads.
    fluxo_vod_drop_gop(session);

    // Without an index the segment may start inside a GOP: the seek goes back about a GOP, to read the key frame
    // before the segment (its pre-roll, see fluxo_vod_route) without seeking again.
    int64_t seek_time = plan->starts[index];
    if (!plan->exact && plan->has_video && index > 0) {
        // (A byte position is estimated from the average bit rate: a second more covers its error.)
        int64_t back = session->vod_gop > 0 ? session->vod_gop + AV_TIME_BASE * 3 / 2 : FLUXO_VOD_PREROLL_BACKOFF;
        seek_time = seek_time - back > plan->starts[0] ? seek_time - back : plan->starts[0];
    }
    // Demuxers emulate seeking on an input that cannot seek by reading and skipping, which can lose their
    // place in the file: such inputs are only read on, or reopened.
    int ret;
    session->vod_seek_position = -1;
    // (The size only of an input that can seek: asking an HTTP input without byte ranges for it costs a request.)
    int seekable = fluxo_vod_input_is_seekable(session->input);
    int64_t size = seekable && !plan->exact && session->input->pb != NULL ? avio_size(session->input->pb) : -1;
    if (!seekable) {
        ret = AVERROR(ENOSYS);
    } else if (!plan->exact && size > 0 && session->input->duration > 0 && (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
        // No index: one request at the estimated byte position (corrected in fluxo_vod_route).
        int64_t start = plan->starts[0];
        int64_t position = (int64_t)((double)(seek_time - start) / (double)session->input->duration * (double)size);
        if (position < 0) {
            position = 0;
        }
        ret = av_seek_frame(session->input, -1, position, AVSEEK_FLAG_BYTE);
        if (ret >= 0) {
            session->vod_seek_time = seek_time;
            session->vod_seek_position = position;
            session->vod_seek_corrections = 0;
        } else {
            ret = av_seek_frame(session->input, -1, seek_time, AVSEEK_FLAG_BACKWARD);
        }
    } else {
        ret = av_seek_frame(session->input, -1, seek_time, AVSEEK_FLAG_BACKWARD);
    }
    int64_t position;
    if (ret >= 0) {
        position = index - 1;
        session->vod_check_seek = 1;
        // What the converters hold belongs to the old position.
        fluxo_streams_reset(&session->streams);
    } else if (index > current) {
        // Reading on reaches it; nothing is written until then.
        position = current;
    } else {
        fluxo_close_input(session);
        ret = fluxo_open_input(session);
        if (ret < 0) {
            return ret;
        }
        fluxo_hls_remap_renditions(session);
        position = -1;
    }
    // Cues read before the jump belong to other segments.
    fluxo_hls_clear_cues(&session->hls);
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = position;
    session->vod_target = index;
    session->vod_ended = 0;
    session->vod_paused = 0;
    pthread_mutex_unlock(&session->vod_lock);
    session->vod_need_key = plan->has_video;
    session->vod_preroll_backoffs = 0;
    // The next key frame read is not a GOP after the previous one.
    session->vod_last_key = AV_NOPTS_VALUE;
    FLUXO_TRACE("seek to segment %lld (%.2f s) from segment %lld: %s", (long long)index, plan->starts[index] / 1e6, (long long)current,
                position == -1 ? "reopened" : (position == current ? "reading on" : "seeked"));
    return 0;
}

// Reopens the input after a read error and positions the reader at the segment it was producing.
// Returns 0 when reading can continue, the error when the input could not be resumed.
static int fluxo_vod_recover(FluxoRemuxSession *session, int error) {
    int64_t resume = session->vod_segment;
    if (!session->vod_writing) {
        resume = resume + 1 > session->vod_target ? resume + 1 : session->vod_target;
    }
    if (resume < 0) {
        resume = 0;
    }
    if (resume >= session->plan.count) {
        resume = session->plan.count - 1;
    }
    fluxo_vod_abort_run(session);
    int ret = error;
    while (!fluxo_is_cancelled(session)) {
        session->vod_recoveries++;
        if (session->vod_recoveries > FLUXO_VOD_MAX_RECOVERIES) {
            return ret;
        }
        session->reconnect_attempt = session->vod_recoveries;
        fluxo_set_state(session, FluxoRemuxStateReconnecting, ret, NULL);
        int shift = session->vod_recoveries - 1 < 4 ? session->vod_recoveries - 1 : 4;
        fluxo_wait(session, (AV_TIME_BASE / 2) << shift);
        if (fluxo_is_cancelled(session)) {
            break;
        }
        fluxo_vod_drop_gop(session);
        fluxo_close_input(session);
        ret = fluxo_open_input(session);
        if (ret < 0) {
            continue;
        }
        fluxo_hls_remap_renditions(session);
        pthread_mutex_lock(&session->vod_lock);
        if (session->vod_reposition < 0) {
            session->vod_reposition = resume;
        }
        pthread_mutex_unlock(&session->vod_lock);
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        return 0;
    }
    return AVERROR_EXIT;
}

// The input was read to its end: the last segment is published and the reader waits for requests (the
// player may seek back to segments that were deleted from the cache).
static int fluxo_vod_finish_input(FluxoRemuxSession *session, AVPacket *scratch) {
    for (int i = 0; i < session->vod_held_count; i++) {
        int ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
        if (ret < 0) {
            return ret;
        }
    }
    fluxo_vod_drop_held(session);
    if (session->vod_writing) {
        int ret = fluxo_vod_finish_segment(session);
        if (ret < 0) {
            return ret;
        }
    }
    fluxo_output_free(&session->hls.output);
    for (int i = 0; i < session->hls.rendition_count; i++) {
        fluxo_output_free(&session->hls.renditions[i].output);
    }
    session->hls.moov_flushed = 0;
    pthread_mutex_lock(&session->vod_lock);
    session->vod_ended = 1;
    // Nothing exists after the segment the reader reached (the plan can be longer than the media: MPEG-TS
    // durations are estimated), nor that segment itself if nothing was written to it.
    int64_t reached = session->vod_segment;
    if (reached >= 0 && reached < session->plan.count) {
        int64_t last = session->plan.bytes[reached] > 0 ? reached : reached - 1;
        if (last >= 0 && last < session->vod_end_segment) {
            session->vod_end_segment = last;
        }
    }
    pthread_mutex_unlock(&session->vod_lock);
    return 0;
}

// True when the reader is far enough ahead of the latest request to pause (with hysteresis: it resumes
// at half the read-ahead).
static int fluxo_vod_should_pause(FluxoRemuxSession *session) {
    const FluxoPlan *plan = &session->plan;
    pthread_mutex_lock(&session->vod_lock);
    int64_t reader = session->vod_segment > session->vod_target ? session->vod_segment : session->vod_target;
    int64_t requested = session->vod_requested;
    if (reader < 0) {
        reader = 0;
    }
    if (reader >= plan->count) {
        reader = plan->count - 1;
    }
    int64_t ahead = plan->starts[reader] - plan->starts[requested];
    int64_t limit = (int64_t)(session->read_ahead * AV_TIME_BASE);
    if (session->vod_paused) {
        session->vod_paused = ahead > limit / 2;
    } else {
        session->vod_paused = ahead > limit;
    }
    int paused = session->vod_paused;
    pthread_mutex_unlock(&session->vod_lock);
    return paused;
}

// Produces the segments of a planned on-demand input until the session is cancelled or the input fails.
static int fluxo_vod_run(FluxoRemuxSession *session) {
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    if (packet == NULL || scratch == NULL) {
        av_packet_free(&packet);
        av_packet_free(&scratch);
        session->output_failed = 1;
        return AVERROR(ENOMEM);
    }
    int ret = 0;
    while (!fluxo_is_cancelled(session)) {
        pthread_mutex_lock(&session->vod_lock);
        int64_t reposition = session->vod_reposition;
        session->vod_reposition = -1;
        int ended = session->vod_ended;
        // Read with the state the reader decides on: a request after it ends the wait below at once.
        uint64_t wakeups = session->vod_wakeups;
        pthread_mutex_unlock(&session->vod_lock);

        if (reposition >= 0) {
            ret = fluxo_vod_seek(session, reposition);
            if (ret < 0) {
                ret = fluxo_vod_recover(session, ret);
                if (ret < 0) {
                    break;
                }
            }
            continue;
        }
        if (ended || fluxo_vod_should_pause(session)) {
            fluxo_vod_wait(session, wakeups, FLUXO_VOD_IDLE_WAIT_US);
            continue;
        }

        if (session->vod_replay_next < session->vod_replay_count) {
            // Packets of the GOP in memory first (fluxo_vod_replay).
            FluxoHeldPacket *held = &session->vod_replay[session->vod_replay_next++];
            av_packet_move_ref(packet, held->packet);
            av_packet_free(&held->packet);
            if (session->vod_replay_next == session->vod_replay_count) {
                session->vod_replay_count = 0;
                session->vod_replay_next = 0;
            }
            ret = 0;
        } else {
            ret = fluxo_streams_read(&session->streams, packet);
        }
        if (ret == AVERROR(EAGAIN)) {
            ret = 0;
            continue;
        }
        if (ret == AVERROR_EOF) {
            // The real end, or a connection the server closed early (then the reader resumes where it was).
            const FluxoPlan *plan = &session->plan;
            int at_end = fluxo_input_reached_end_of_file(session) || session->vod_segment >= plan->count - 1 ||
                         session->input->pb == NULL || avio_size(session->input->pb) <= 0;
            if (at_end) {
                ret = fluxo_vod_finish_input(session, scratch);
                if (ret < 0) {
                    session->output_failed = 1;
                    break;
                }
                ret = 0;
                continue;
            }
        }
        if (ret < 0) {
            ret = fluxo_vod_recover(session, ret);
            if (ret < 0) {
                break;
            }
            continue;
        }
        if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= session->input->nb_streams ||
            !(fluxo_is_stream_supported(session->input->streams[packet->stream_index]) ||
              fluxo_hls_is_subtitle_source(&session->hls, packet->stream_index))) {
            av_packet_unref(packet);
            continue;
        }
        fluxo_vod_remember(session, packet);
        ret = fluxo_vod_route(session, packet, scratch);
        av_packet_unref(packet);
        if (ret < 0) {
            session->output_failed = 1;
            break;
        }
    }
    if (fluxo_is_cancelled(session) && ret >= 0) {
        ret = AVERROR_EXIT;
    }
    fluxo_vod_abort_run(session);
    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

// Prepares the output of a planned on-demand input: the segment format and the complete playlist.
static int fluxo_vod_open(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    hls->fragmented = fluxo_hls_wants_fragmented_mp4(session->input);
    hls->segment_extension = hls->fragmented ? "m4s" : "ts";
    // Extra audio tracks and text subtitles: renditions of a master playlist, with the same segments (audio in
    // fragmented MP4 too next to fMP4 video).
    int ret = fluxo_hls_plan_renditions(session);
    if (ret < 0) {
        return ret;
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        hls->renditions[i].fragmented = hls->fragmented && hls->renditions[i].type == FluxoRenditionAudio;
    }
    // Output timestamps: the input timeline from the first segment, plus the base.
    session->timestamp_offset = FLUXO_TIMESTAMP_BASE - session->plan.starts[0];
    // A resume starts with the segment at the start time (found by bisection: the plan is sorted).
    int64_t first = 0;
    if (session->start_time > 0) {
        int64_t time = session->plan.starts[0] + session->start_time;
        int64_t low = 0;
        int64_t high = session->plan.count - 1;
        while (low < high) {
            int64_t middle = (low + high + 1) / 2;
            if (session->plan.starts[middle] <= time) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        first = low;
        FLUXO_TRACE("start at %.2f s: segment %lld", session->start_time / 1e6, (long long)first);
    }
    if (first == 0 && !session->plan.exact && fluxo_vod_input_is_seekable(session->input) && session->input->pb != NULL &&
        (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
        // From the very start of the file (probing and the index check leave the reader somewhere after it): its first
        // video frame, a key frame, is where AVPlayer places the first segment.
        av_seek_frame(session->input, -1, 0, AVSEEK_FLAG_BYTE);
        fluxo_streams_reset(&session->streams);
    }
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = -1;
    session->vod_target = 0;
    session->vod_requested = first;
    session->vod_reposition = first > 0 ? first : -1;
    session->vod_regenerate = -1;
    session->vod_last_key = AV_NOPTS_VALUE;
    session->vod_seek_position = -1;
    session->vod_gop = 0;
    pthread_mutex_unlock(&session->vod_lock);
    ret = fluxo_vod_write_playlist(session);
    if (ret >= 0) {
        pthread_mutex_lock(&session->vod_lock);
        session->vod_playlist_written = 1;
        pthread_mutex_unlock(&session->vod_lock);
    }
    return ret;
}

static void *fluxo_thread_main(void *arg) {
    FluxoRemuxSession *session = arg;
    fluxo_set_state(session, FluxoRemuxStateOpening, 0, NULL);

    const char *stage = "Unable to open the stream";
    // Set when a live input could not be reconnected: always a failure, even if the last error was EOF.
    int reconnect_failed = 0;
    session->is_first_open = 1;
    int ret = fluxo_open_input(session);
    // A missing protocol (e.g. srt://, which needs libsrt) is not a transient error: no retry. One quick retry
    // otherwise: IPTV servers often refuse the very first connection of a burst. Accounts limited to one
    // connection refuse new ones (403, 429, 5xx) until they notice the previous one closed (the channel played
    // before, or AVPlayer's own connections to a movie the engine takes over): two more, 1 s and 2 s later.
    // Nor a format that cannot be played.
    for (int attempt = 1; ret < 0 && ret != AVERROR_PROTOCOL_NOT_FOUND && ret != FLUXO_ERROR_UNSUPPORTED_VIDEO &&
                          ret != FLUXO_ERROR_UNSUPPORTED_AUDIO && !fluxo_is_cancelled(session) && attempt <= 3; attempt++) {
        if (attempt > 1 && !fluxo_is_busy_server_error(ret)) {
            break;
        }
        fluxo_wait(session, (AV_TIME_BASE / 2) << (attempt - 1));
        if (!fluxo_is_cancelled(session)) {
            ret = fluxo_open_input(session);
        }
    }
    session->is_first_open = 0;
    int planned = 0;
    if (ret >= 0) {
        int64_t start = session->input->start_time;
        session->timestamp_offset = (start == AV_NOPTS_VALUE ? 0 : -start) + FLUXO_TIMESTAMP_BASE;
        session->last_input_dts = AV_NOPTS_VALUE;

        stage = "Unable to create the HLS output";
        if (!session->is_live) {
            ret = fluxo_vod_plan(session);
            planned = ret > 0;
            if (planned) {
                pthread_mutex_lock(&session->vod_lock);
                session->on_demand = 1;
                pthread_mutex_unlock(&session->vod_lock);
                ret = fluxo_vod_open(session);
            }
        }
        if (ret >= 0 && !planned) {
            if (!session->is_live) {
                // Every segment stays listed (EXT-X-PLAYLIST-TYPE:EVENT), so that every position read so
                // far stays seekable; the budget only slows reading down (fluxo_run_loop).
                session->vod_budget_bytes = session->hls.max_window_bytes;
                session->hls.max_window_bytes = 0;
                session->hls.max_window_duration = 0;
            }
            ret = fluxo_hls_open(session);
        }
    }
    if (ret >= 0 && planned) {
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        stage = "Stream interrupted";
        ret = fluxo_vod_run(session);
        if (session->output_failed) {
            stage = "Unable to write the stream";
        }
    } else if (ret >= 0) {
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        for (;;) {
            stage = "Stream interrupted";
            ret = fluxo_run_loop(session);
            if (fluxo_is_cancelled(session) || session->output_failed || !session->is_live) {
                break;
            }
            if (ret == AVERROR_EOF && fluxo_input_reached_end_of_file(session)) {
                // A finite file served over HTTP (e.g. an on-demand .ts): it really ended.
                break;
            }
            // Live inputs never end on their own: a drop or an EOF means the connection was lost.
            stage = "Connection lost";
            ret = fluxo_reconnect(session, ret);
            if (ret < 0) {
                reconnect_failed = !fluxo_is_cancelled(session);
                break;
            }
        }
        if (session->output_failed) {
            stage = "Unable to write the stream";
        }
    }

    int cancelled = fluxo_is_cancelled(session);
    int finished = !cancelled && !reconnect_failed && !session->output_failed && (ret == AVERROR_EOF || ret >= 0);

    fluxo_recording_close(session, 0, NULL);
    fluxo_drain_requests(session);
    if (planned) {
        // The VOD playlist stays as it is; only the partial segment goes (fluxo_vod_run).
        fluxo_vod_abort_run(session);
    } else {
        fluxo_hls_close(session, !cancelled);
    }
    fluxo_close_input(session);

    if (cancelled) {
        fluxo_set_state(session, FluxoRemuxStateCancelled, 0, NULL);
    } else if (finished) {
        fluxo_set_state(session, FluxoRemuxStateFinished, 0, NULL);
    } else {
        if (ret >= 0) {
            ret = AVERROR_UNKNOWN;
        }
        char message[512];
        if (ret == AVERROR_PROTOCOL_NOT_FOUND) {
            fluxo_format_unsupported_protocol(message, sizeof(message), session->input_url);
        } else if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            // StreamRemuxer.swift (EngineMessage) recognizes these.
            snprintf(message, sizeof(message), "%s: %s", ret == FLUXO_ERROR_UNSUPPORTED_VIDEO ? "Unsupported video format" : "Unsupported audio format",
                     session->streams.unsupported_codec[0] != '\0' ? session->streams.unsupported_codec : "unknown");
        } else {
            fluxo_format_error(message, sizeof(message), ret, stage);
        }
        fluxo_set_state(session, FluxoRemuxStateFailed, ret, message);
    }
    return NULL;
}

// MARK: - Public API

FluxoRemuxSession *fluxo_remux_create(const FluxoRemuxConfig *config, FluxoRemuxEventCallback callback, void *context) {
    if (config == NULL || config->input_url == NULL || config->hls.playlist_path == NULL || config->hls.segment_path_prefix == NULL) {
        return NULL;
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    FluxoRemuxSession *session = calloc(1, sizeof(FluxoRemuxSession));
    if (session == NULL) {
        return NULL;
    }
    pthread_mutex_init(&session->request_lock, NULL);
    pthread_mutex_init(&session->vod_lock, NULL);
    pthread_cond_init(&session->vod_cond, NULL);
    session->vod_reposition = -1;
    session->vod_segment = -1;
    session->vod_seek_hint = AV_NOPTS_VALUE;
    session->vod_read_time = AV_NOPTS_VALUE;
    session->read_ahead = config->read_ahead_duration > 0 ? config->read_ahead_duration : FLUXO_DEFAULT_READ_AHEAD;
    session->start_time = config->start_time > 0 ? (int64_t)(config->start_time * AV_TIME_BASE) : 0;
    atomic_init(&session->cancel_requested, false);
    atomic_init(&session->started, false);
    atomic_init(&session->request_pending, false);

    session->input_url = fluxo_strdup(config->input_url);
    session->user_agent = fluxo_strdup(config->user_agent);
    session->io_timeout_us = config->io_timeout_us > 0 ? config->io_timeout_us : FLUXO_DEFAULT_IO_TIMEOUT_US;
    session->is_live = config->is_live != 0;
    session->max_reconnect_attempts = config->max_reconnect_attempts == 0 ? FLUXO_DEFAULT_RECONNECT_ATTEMPTS : config->max_reconnect_attempts;
    session->quick_open = config->quick_open != 0;
    session->callback = callback;
    session->context = context;
    session->state = FluxoRemuxStateIdle;
    session->timestamp_offset = 0;
    session->last_input_dts = AV_NOPTS_VALUE;
    session->recording.first_time = AV_NOPTS_VALUE;
    session->recording.last_time = AV_NOPTS_VALUE;
    session->recording.output.video_index = -1;

    FluxoHLS *hls = &session->hls;
    hls->output.video_index = -1;
    hls->playlist_path = fluxo_strdup(config->hls.playlist_path);
    hls->segment_prefix = fluxo_strdup(config->hls.segment_path_prefix);
    hls->segment_duration = config->hls.segment_duration > 0 ? config->hls.segment_duration : 2.0;
    hls->max_window_duration = config->hls.max_window_duration > 0 ? config->hls.max_window_duration : 0;
    hls->max_window_bytes = config->hls.max_window_bytes > 0 ? config->hls.max_window_bytes : 0;
    hls->min_window_segments = config->hls.min_window_segments > 0 ? config->hls.min_window_segments : 3;
    hls->program_date_time = session->is_live;
    hls->segment_start_time = AV_NOPTS_VALUE;
    hls->segment_cut_on_audio = 0;
    hls->last_reference_time = AV_NOPTS_VALUE;
    hls->master_path = fluxo_strdup(config->hls.master_playlist_path);
    if (hls->master_path != NULL) {
        size_t master_length = strlen(hls->master_path) + 5;
        hls->master_tmp_path = malloc(master_length);
        if (hls->master_tmp_path == NULL) {
            free(hls->master_path);
            hls->master_path = NULL;
        } else {
            snprintf(hls->master_tmp_path, master_length, "%s.tmp", hls->master_path);
        }
    }
    hls->segment_extension = "ts";

    if (session->input_url == NULL || hls->playlist_path == NULL || hls->segment_prefix == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    size_t length = strlen(hls->playlist_path) + 5;
    hls->playlist_tmp_path = malloc(length);
    if (hls->playlist_tmp_path == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    snprintf(hls->playlist_tmp_path, length, "%s.tmp", hls->playlist_path);
    length = strlen(hls->segment_prefix) + sizeof("-init.mp4");
    hls->init_path = malloc(length);
    if (hls->init_path == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    snprintf(hls->init_path, length, "%s-init.mp4", hls->segment_prefix);
    const char *slash = strrchr(hls->segment_prefix, '/');
    hls->segment_base_name = slash != NULL ? slash + 1 : hls->segment_prefix;
    return session;
}

int32_t fluxo_remux_start(FluxoRemuxSession *session) {
    if (session == NULL || atomic_exchange(&session->started, true)) {
        return -1;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 1024 * 1024);
    int ret = pthread_create(&session->thread, &attributes, fluxo_thread_main, session);
    pthread_attr_destroy(&attributes);
    if (ret != 0) {
        return -ret;
    }
    session->thread_created = 1;
    return 0;
}

void fluxo_remux_cancel(FluxoRemuxSession *session) {
    if (session != NULL) {
        atomic_store(&session->cancel_requested, true);
        fluxo_vod_signal(session);
    }
}

int32_t fluxo_remux_request_segment(FluxoRemuxSession *session, int64_t index, int32_t is_rendition) {
    if (session == NULL || session->is_live) {
        return -1;
    }
    int32_t result;
    pthread_mutex_lock(&session->vod_lock);
    if (index == -1) {
        // The initialization segment of fMP4 playlists, written with the first segment.
        result = session->vod_init_ready ? 1 : 0;
    } else if (index < 0) {
        result = -1;
    } else if (!session->on_demand) {
        // Remuxed from start to end: segments are listed as they are written.
        if (!is_rendition) {
            session->vod_requested = index;
        }
        result = index < session->vod_available ? 1 : 0;
    } else if (index >= session->plan.count || index > session->vod_end_segment) {
        result = -2;
    } else if (is_rendition) {
        // Produced with the main segment of the same number; only the main playlist moves the reader (players
        // load the audio and subtitle segments of a rendition about where they load the video, some ahead).
        result = session->plan.bytes[index] > 0 ? 1 : 0;
    } else {
        int64_t previous = session->vod_requested;
        session->vod_requested = index;
        // A request that does not follow the previous one is a seek. So is the segment a seek the player announced
        // goes to (fluxo_remux_note_seek), even when it is the next one: a seek just past what the player buffered
        // asks for the segment after the last one it loaded, which the reader may have written ahead without a key
        // frame at its start; served as written, playback would start at its next key frame, seconds late.
        int is_seek = index != previous && index != previous + 1;
        if (session->vod_seek_hint != AV_NOPTS_VALUE) {
            int64_t time = session->plan.starts[0] + session->vod_seek_hint;
            if (time >= session->plan.starts[index] - FLUXO_VOD_SEEK_HINT_MARGIN && time < session->plan.starts[index + 1]) {
                is_seek = 1;
            }
            session->vod_seek_hint = AV_NOPTS_VALUE;
        }
        if (session->plan.bytes[index] > 0 && is_seek && !session->plan.exact && session->plan.has_video && !session->plan.independent[index]) {
            // A seek into a segment that starts inside a GOP would show a frozen picture until the next key frame:
            // it is written again from the key frame before it.
            result = 0;
            session->vod_regenerate = index;
            session->vod_reposition = index;
        } else if (session->plan.bytes[index] > 0) {
            result = 1;
        } else {
            result = 0;
            // The segment the reader produces next: the one it is in, or the one it seeks to.
            int64_t reader = session->vod_segment > session->vod_target ? session->vod_segment : session->vod_target;
            if (reader >= session->plan.count) {
                reader = session->plan.count - 1;
            }
            if (session->vod_ended || index < reader || session->plan.starts[index] - session->plan.starts[reader] > FLUXO_VOD_READ_ON_TIME) {
                session->vod_reposition = index;
            } else if (is_seek && !session->plan.exact && session->plan.has_video && index > 0 &&
                       !(session->vod_target == index && session->vod_segment <= index)) {
                // A seek into the segment the reader writes now, or reaches by reading on: without an index it would be
                // cut at its planned time inside a GOP, and play from its next key frame, seconds after the target. It
                // starts a run of its own instead, with its pre-roll (from the GOP in memory, see fluxo_vod_replay: no
                // network). Not for the first segment of the reader's run (it heads for it, or writes it): that one starts
                // with its pre-roll already.
                session->vod_reposition = index;
            }
        }
    }
    fluxo_vod_signal_locked(session);
    pthread_mutex_unlock(&session->vod_lock);
    return result;
}

void fluxo_remux_note_seek(FluxoRemuxSession *session, double seconds) {
    if (session == NULL || session->is_live || !isfinite(seconds)) {
        return;
    }
    pthread_mutex_lock(&session->vod_lock);
    session->vod_seek_hint = seconds > 0 ? (int64_t)(seconds * AV_TIME_BASE) : 0;
    pthread_mutex_unlock(&session->vod_lock);
}

int32_t fluxo_remux_set_start_time(FluxoRemuxSession *session, double seconds) {
    if (session == NULL || session->is_live || !isfinite(seconds)) {
        return -1;
    }
    int32_t result = -1;
    pthread_mutex_lock(&session->vod_lock);
    // Only once the engine wrote the playlists: it never writes them again, and it reads start_time before.
    if (session->on_demand && session->vod_playlist_written) {
        session->start_time = seconds > 0 ? (int64_t)(seconds * AV_TIME_BASE) : 0;
        result = fluxo_vod_write_playlist(session) < 0 ? -1 : 0;
    }
    pthread_mutex_unlock(&session->vod_lock);
    return result;
}

int32_t fluxo_remux_start_recording(FluxoRemuxSession *session, const char *path) {
    if (session == NULL || path == NULL || path[0] == '\0') {
        return -1;
    }
    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    pthread_mutex_lock(&session->request_lock);
    fluxo_discard_pending_recording_locked(session);
    session->pending_recording_path = copy;
    session->pending_recording_stop = 0;
    atomic_store(&session->request_pending, true);
    pthread_mutex_unlock(&session->request_lock);
    // A paused on-demand reader applies requests when it wakes up.
    fluxo_vod_signal(session);
    return 0;
}

void fluxo_remux_stop_recording(FluxoRemuxSession *session) {
    if (session == NULL) {
        return;
    }
    pthread_mutex_lock(&session->request_lock);
    fluxo_discard_pending_recording_locked(session);
    session->pending_recording_stop = 1;
    atomic_store(&session->request_pending, true);
    pthread_mutex_unlock(&session->request_lock);
    fluxo_vod_signal(session);
}

void fluxo_remux_destroy(FluxoRemuxSession *session) {
    if (session == NULL) {
        return;
    }
    fluxo_remux_cancel(session);
    if (session->thread_created) {
        pthread_join(session->thread, NULL);
        session->thread_created = 0;
    }
    // Only reached without a thread when start failed: nothing was opened.
    fluxo_output_free(&session->recording.output);
    free(session->recording.path);
    fluxo_output_free(&session->hls.output);
    fluxo_close_input(session);

    free(session->input_url);
    free(session->user_agent);
    free(session->hls.playlist_path);
    free(session->hls.playlist_tmp_path);
    free(session->hls.segment_prefix);
    free(session->hls.segments);
    fluxo_hls_free_renditions(&session->hls);
    free(session->hls.master_path);
    free(session->hls.master_tmp_path);
    free(session->hls.init_path);
    fluxo_vod_drop_held(session);
    free(session->vod_held);
    fluxo_vod_drop_preroll(session);
    free(session->vod_preroll);
    fluxo_vod_drop_gop(session);
    free(session->vod_kept);
    free(session->vod_replay);
    fluxo_vod_plan_free(&session->plan);
    free(session->pending_recording_path);
    fluxo_free_discarded_recordings(session->discarded_recordings);
    pthread_mutex_destroy(&session->request_lock);
    pthread_cond_destroy(&session->vod_cond);
    pthread_mutex_destroy(&session->vod_lock);
    free(session);
}

// MARK: - File conversion

_Static_assert(FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE == FLUXO_ERROR_ENCODER_UNAVAILABLE, "one error code for Swift and the converter");

int32_t fluxo_remux_convert_file(const char *input_path, const char *output_path, double *duration_seconds,
                                 char *error_message, int32_t error_message_size) {
    if (input_path == NULL || output_path == NULL) {
        return AVERROR(EINVAL);
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    AVFormatContext *input = NULL;
    FluxoStreams streams;
    memset(&streams, 0, sizeof(streams));
    FluxoOutput output;
    memset(&output, 0, sizeof(output));
    output.video_index = -1;
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    const char *stage = "Unable to open the recording";
    int64_t first_time = AV_NOPTS_VALUE;
    int64_t last_time = AV_NOPTS_VALUE;
    int output_opened = 0;

    int ret = packet != NULL && scratch != NULL ? 0 : AVERROR(ENOMEM);
    if (ret >= 0) {
        ret = avformat_open_input(&input, input_path, NULL, NULL);
    }
    if (ret >= 0) {
        ret = avformat_find_stream_info(input, NULL);
    }
    if (ret >= 0) {
        // What AVPlayer cannot decode (DTS audio, MPEG-4 Part 2 video of a downloaded movie, ...) is converted.
        FluxoStreamsOptions streams_options = {.is_live = 0, .global_header = 1, .key_interval = 4, .complete = 1};
        ret = fluxo_streams_open(&streams, input, &streams_options);
        if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            stage = ret == FLUXO_ERROR_UNSUPPORTED_VIDEO ? "Unsupported video format" : "Unsupported audio format";
        }
    }
    if (ret >= 0) {
        stage = "Unable to create the output file";
        ret = fluxo_output_prepare(&output, input, NULL, output_path);
    }
    if (ret >= 0) {
        // Everything is kept, including audio that precedes the first key frame.
        output.wait_keyframe = 0;
        ret = avio_open(&output.context->pb, output_path, AVIO_FLAG_WRITE);
        output_opened = ret >= 0;
    }
    if (ret >= 0) {
        AVDictionary *options = NULL;
        // The index goes first so that the file starts playing (and seeking) immediately.
        av_dict_set(&options, "movflags", "+faststart", 0);
        ret = avformat_write_header(output.context, &options);
        av_dict_free(&options);
        if (ret >= 0) {
            output.header_written = 1;
        }
    }

    int64_t start = input != NULL && input->start_time != AV_NOPTS_VALUE ? input->start_time : 0;
    if (ret >= 0) {
        stage = "Unable to convert the recording";
        while ((ret = fluxo_streams_read(&streams, packet)) >= 0) {
            if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= input->nb_streams) {
                av_packet_unref(packet);
                continue;
            }
            AVStream *in_stream = input->streams[packet->stream_index];
            int64_t offset = av_rescale_q(start, AV_TIME_BASE_Q, in_stream->time_base);
            if (packet->pts != AV_NOPTS_VALUE) {
                packet->pts -= offset;
            }
            if (packet->dts != AV_NOPTS_VALUE) {
                packet->dts -= offset;
            }
            int prepared = fluxo_output_prepare_packet(&output, packet, in_stream, scratch);
            av_packet_unref(packet);
            if (prepared < 0) {
                ret = prepared;
                break;
            }
            if (prepared == 0) {
                continue;
            }
            int64_t time = fluxo_packet_time(scratch, output.context->streams[scratch->stream_index]);
            if (time != AV_NOPTS_VALUE) {
                int64_t end = time + av_rescale_q(scratch->duration, output.context->streams[scratch->stream_index]->time_base, AV_TIME_BASE_Q);
                if (first_time == AV_NOPTS_VALUE || time < first_time) {
                    first_time = time;
                }
                if (last_time == AV_NOPTS_VALUE || end > last_time) {
                    last_time = end;
                }
            }
            if (scratch->dts != AV_NOPTS_VALUE) {
                output.last_dts[scratch->stream_index] = scratch->dts;
            }
            ret = av_interleaved_write_frame(output.context, scratch);
            av_packet_unref(scratch);
            if (ret < 0 && ret != AVERROR(EINVAL)) {
                break;
            }
            ret = 0;
        }
        if (ret == AVERROR_EOF) {
            ret = 0;
        }
        if (ret >= 0) {
            ret = av_write_trailer(output.context);
        }
    }

    if (ret < 0 && error_message != NULL && error_message_size > 0) {
        if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            snprintf(error_message, (size_t)error_message_size, "%s: %s", stage, streams.unsupported_codec[0] != '\0' ? streams.unsupported_codec : "unknown");
        } else if (ret == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
            snprintf(error_message, (size_t)error_message_size, "%s", "Video encoder unavailable");
        } else {
            fluxo_format_error(error_message, (size_t)error_message_size, ret, stage);
        }
    }
    if (duration_seconds != NULL) {
        *duration_seconds = first_time != AV_NOPTS_VALUE && last_time > first_time ? (double)(last_time - first_time) / AV_TIME_BASE : 0;
    }

    fluxo_output_free(&output);
    fluxo_streams_close(&streams);
    if (input != NULL) {
        avformat_close_input(&input);
    }
    av_packet_free(&packet);
    av_packet_free(&scratch);
    if (ret < 0 && output_opened) {
        unlink(output_path);
    }
    return ret < 0 ? ret : 0;
}

const char *fluxo_remux_library_version(void) {
    return av_version_info();
}
