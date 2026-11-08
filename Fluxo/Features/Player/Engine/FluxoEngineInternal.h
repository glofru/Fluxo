//
//  FluxoEngineInternal.h
//  Fluxo
//
//  Internal to the remux engine; not exposed to Swift (the bridging header includes FluxoRemuxEngine.h only).
//  Shared by its C files (FluxoRemuxEngine.c and the FluxoEngine*.c files): the limits, the types of a session, and
//  the functions one file calls in another. Everything else of a file stays static in it.
//

#ifndef FLUXO_ENGINE_INTERNAL_H
#define FLUXO_ENGINE_INTERNAL_H

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


// Longest sleep of a paused on-demand reader. Every request wakes it at once (fluxo_vod_signal): this only bounds
// the sleep should a wake-up ever be missed. While it waits, the engine thread costs nothing (it used to wake up
// four times a second for a whole movie once it was read ahead, or read to its end).
#define FLUXO_VOD_IDLE_WAIT_US (5 * 1000000LL)

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


// MARK: - Functions shared by the engine's files

// Not exported from the binary that links the engine.
#pragma GCC visibility push(hidden)

// FluxoRemuxEngine.c
int64_t fluxo_wallclock_ms(void);
int fluxo_is_cancelled(FluxoRemuxSession *session);
int fluxo_interrupt_callback(void *opaque);
int fluxo_is_stream_supported(const AVStream *stream);
void fluxo_emit_with_path(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message,
                          const char *explicit_path);
void fluxo_emit(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message);
void fluxo_set_state(FluxoRemuxSession *session, FluxoRemuxState state, int error_code, const char *message);
void fluxo_format_error(char *buffer, size_t size, int error_code, const char *what);

// FluxoEngineInput.c
int fluxo_open_input(FluxoRemuxSession *session);
int fluxo_is_busy_server_error(int error);
int fluxo_input_reached_end_of_file(FluxoRemuxSession *session);
void fluxo_close_input(FluxoRemuxSession *session);

// FluxoEngineOutput.c
void fluxo_output_free(FluxoOutput *output);
int fluxo_output_map_input(FluxoOutput *output, AVFormatContext *input);
int fluxo_output_prepare(FluxoOutput *output, AVFormatContext *input, const char *format_name, const char *path);
int fluxo_output_prepare_packet(FluxoOutput *output, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch);
int fluxo_output_commit(FluxoOutput *output, AVPacket *scratch);
int64_t fluxo_packet_time(const AVPacket *packet, const AVStream *stream);

// FluxoEngineHLS.c
void fluxo_hls_segment_path(const FluxoHLS *hls, int64_t sequence, int temporary, char *buffer, size_t size);
int fluxo_publish_file(FILE *file, const char *tmp_path, const char *path);
void fluxo_write_map(FILE *file, const char *init_path);
int fluxo_hls_wants_fragmented_mp4(const AVFormatContext *input);
int fluxo_output_write_header(FluxoOutput *output, int fragmented);
int fluxo_output_flush(FluxoOutput *output, int fragmented, const char *init_path, int *init_written, int *moov_flushed);
void fluxo_hls_align_muxer(FluxoHLS *hls, AVFormatContext *context);
int fluxo_hls_prepare_output(FluxoRemuxSession *session);
int fluxo_hls_write_header(FluxoHLS *hls);
int fluxo_hls_flush(FluxoHLS *hls);
void fluxo_hls_delete_segment(const FluxoHLS *hls, int64_t sequence);
int fluxo_hls_open(FluxoRemuxSession *session);
int fluxo_hls_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch);
int fluxo_hls_break(FluxoRemuxSession *session);
void fluxo_hls_close(FluxoRemuxSession *session, int ended);

// FluxoEngineRenditions.c
const char *fluxo_rendition_extension(const FluxoRendition *rendition);
void fluxo_hls_free_renditions(FluxoHLS *hls);
int fluxo_hls_plan_renditions(FluxoRemuxSession *session);
int fluxo_hls_prepare_renditions(FluxoRemuxSession *session);
int fluxo_hls_write_rendition_headers(FluxoHLS *hls);
void fluxo_hls_remap_renditions(FluxoRemuxSession *session);
int fluxo_hls_open_rendition_segments(FluxoHLS *hls, int64_t sequence, int resend_headers);
int64_t fluxo_hls_close_rendition_segments(FluxoHLS *hls, int64_t sequence, int flush, int publish);
int64_t fluxo_hls_write_subtitle_segments(FluxoHLS *hls, int64_t sequence, int64_t start, int64_t end, int last);
void fluxo_hls_delete_rendition_segments(const FluxoHLS *hls, int64_t sequence);
int fluxo_hls_write_renditions(FluxoHLS *hls, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch);
int fluxo_hls_is_subtitle_source(const FluxoHLS *hls, int index);
void fluxo_hls_clear_cues(FluxoHLS *hls);

// FluxoEngineText.c
void fluxo_language_tag(const char *language, char *buffer, size_t size);
void fluxo_attribute_text(const char *text, char *buffer, size_t size);
char *fluxo_subtitle_text(enum AVCodecID codec_id, const uint8_t *data, int size);

// FluxoEngineMasterPlaylist.c
int fluxo_packet_has_closed_captions(const AVPacket *packet);
int fluxo_hls_write_master(FluxoRemuxSession *session);

// FluxoEngineRecording.c
void fluxo_recording_close(FluxoRemuxSession *session, int error_code, const char *message);
int fluxo_recording_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch);
void fluxo_discard_pending_recording_locked(FluxoRemuxSession *session);
void fluxo_free_discarded_recordings(FluxoDiscardedRecording *list);
void fluxo_process_requests(FluxoRemuxSession *session);
void fluxo_drain_requests(FluxoRemuxSession *session);

// FluxoEngineLive.c
int fluxo_run_loop(FluxoRemuxSession *session);
void fluxo_wait(FluxoRemuxSession *session, int64_t duration_us);
int fluxo_reconnect(FluxoRemuxSession *session, int last_error);

// FluxoEngineVODPlan.c
void fluxo_vod_signal_locked(FluxoRemuxSession *session);
void fluxo_vod_signal(FluxoRemuxSession *session);
void fluxo_vod_wait(FluxoRemuxSession *session, uint64_t wakeups, int64_t timeout_us);
int fluxo_compare_times(const void *a, const void *b);
int64_t fluxo_vod_packet_time(const FluxoPlan *plan, const AVPacket *packet, const AVStream *stream, int key_clock);
int fluxo_vod_input_is_seekable(const AVFormatContext *input);
int fluxo_vod_plan(FluxoRemuxSession *session);
void fluxo_vod_plan_free(FluxoPlan *plan);
int fluxo_vod_write_playlist(FluxoRemuxSession *session);

// FluxoEngineVODPackets.c
void fluxo_vod_drop_held(FluxoRemuxSession *session);
void fluxo_vod_drop_preroll(FluxoRemuxSession *session);
void fluxo_vod_drop_gop(FluxoRemuxSession *session);
void fluxo_vod_remember(FluxoRemuxSession *session, const AVPacket *packet);
int fluxo_vod_replay(FluxoRemuxSession *session, int64_t index);
int fluxo_vod_add_preroll(FluxoRemuxSession *session, const AVPacket *packet, int64_t time);
int fluxo_vod_hold(FluxoRemuxSession *session, const AVPacket *packet, int64_t time);

// FluxoEngineVOD.c
void fluxo_vod_abort_run(FluxoRemuxSession *session);
int fluxo_vod_run(FluxoRemuxSession *session);
int fluxo_vod_open(FluxoRemuxSession *session);

#pragma GCC visibility pop

#endif /* FLUXO_ENGINE_INTERNAL_H */
