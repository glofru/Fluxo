//
//  FluxoEngineVODPackets.c
//  Fluxo
//
//  On-demand inputs: the packets the engine keeps in memory (held at a cut, the pre-roll of a seek, the GOP of
//  the latest key frame) and replays.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

void fluxo_vod_drop_held(FluxoRemuxSession *session) {
    for (int i = 0; i < session->vod_held_count; i++) {
        av_packet_free(&session->vod_held[i].packet);
    }
    session->vod_held_count = 0;
}

void fluxo_vod_drop_preroll(FluxoRemuxSession *session) {
    for (int i = 0; i < session->vod_preroll_count; i++) {
        av_packet_free(&session->vod_preroll[i].packet);
    }
    session->vod_preroll_count = 0;
}

// Forgets the packets of the GOP in memory and those still to replay (the input moved: they no longer lead to
// where it reads).
void fluxo_vod_drop_gop(FluxoRemuxSession *session) {
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
void fluxo_vod_remember(FluxoRemuxSession *session, const AVPacket *packet) {
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
int fluxo_vod_replay(FluxoRemuxSession *session, int64_t index) {
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
int fluxo_vod_add_preroll(FluxoRemuxSession *session, const AVPacket *packet, int64_t time) {
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

int fluxo_vod_hold(FluxoRemuxSession *session, const AVPacket *packet, int64_t time) {
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
