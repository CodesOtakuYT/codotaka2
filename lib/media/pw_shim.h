// Minimal PipeWire playback stream for Zig. SPA's format builders are inline/macro heavy,
// so the stream setup lives in C; everything else (ring buffer, clock, policy) is Zig.
#pragma once
#include <stdbool.h>
#include <stdint.h>

struct cdk_audio;

// Called on PipeWire's realtime thread: fill `frames` interleaved f32 frames into `out`.
// `heard_at_ns` is the CLOCK_MONOTONIC time at which out[0] will reach the speakers
// (now + graph/device latency, from pw_stream_get_time_n).
typedef void (*cdk_audio_fill)(void *user, float *out, uint32_t frames, int64_t heard_at_ns);

struct cdk_audio *cdk_audio_open(const char *name, uint32_t rate, uint32_t channels, cdk_audio_fill fill, void *user);
void cdk_audio_set_active(struct cdk_audio *a, bool active);
void cdk_audio_close(struct cdk_audio *a);
