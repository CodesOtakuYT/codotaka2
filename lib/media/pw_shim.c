#include "pw_shim.h"

#include <stdlib.h>
#include <time.h>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

struct cdk_audio {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    cdk_audio_fill fill;
    void *user;
    uint32_t rate;
    uint32_t channels;
};

static int64_t monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * SPA_NSEC_PER_SEC + ts.tv_nsec;
}

static void on_process(void *data) {
    struct cdk_audio *a = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(a->stream);
    if (!b) return;
    struct spa_buffer *buf = b->buffer;
    float *dst = buf->datas[0].data;
    if (!dst) return;
    uint32_t stride = sizeof(float) * a->channels;
    uint32_t frames = buf->datas[0].maxsize / stride;
    if (b->requested && b->requested < frames) frames = (uint32_t)b->requested;

    // Latency until this buffer is heard: device/graph delay (in ticks of t.rate) plus
    // frames still buffered in the stream's converter.
    struct pw_time t;
    int64_t delay_ns = 0;
    if (pw_stream_get_time_n(a->stream, &t, sizeof(t)) == 0) {
        if (t.rate.denom)
            delay_ns = t.delay * (int64_t)SPA_NSEC_PER_SEC * t.rate.num / t.rate.denom;
        delay_ns += (int64_t)t.buffered * SPA_NSEC_PER_SEC / a->rate;
    }
    a->fill(a->user, dst, frames, monotonic_ns() + delay_ns);

    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = stride;
    buf->datas[0].chunk->size = frames * stride;
    pw_stream_queue_buffer(a->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .process = on_process,
};

struct cdk_audio *cdk_audio_open(const char *name, uint32_t rate, uint32_t channels, cdk_audio_fill fill, void *user) {
    pw_init(NULL, NULL);
    struct cdk_audio *a = calloc(1, sizeof(*a));
    if (!a) return NULL;
    a->fill = fill;
    a->user = user;
    a->rate = rate;
    a->channels = channels;

    a->loop = pw_thread_loop_new(name, NULL);
    if (!a->loop) goto fail;
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Movie",
        PW_KEY_APP_NAME, name,
        NULL);
    a->stream = pw_stream_new_simple(pw_thread_loop_get_loop(a->loop), name, props, &stream_events, a);
    if (!a->stream) goto fail;

    uint8_t pod_buf[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod_buf, sizeof(pod_buf));
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .channels = channels, .rate = rate));

    if (pw_stream_connect(a->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
            params, 1) < 0)
        goto fail;
    if (pw_thread_loop_start(a->loop) < 0) goto fail;
    return a;

fail:
    cdk_audio_close(a);
    return NULL;
}

void cdk_audio_set_active(struct cdk_audio *a, bool active) {
    pw_thread_loop_lock(a->loop);
    pw_stream_set_active(a->stream, active);
    pw_thread_loop_unlock(a->loop);
}

void cdk_audio_close(struct cdk_audio *a) {
    if (!a) return;
    if (a->loop) pw_thread_loop_stop(a->loop);
    if (a->stream) pw_stream_destroy(a->stream);
    if (a->loop) pw_thread_loop_destroy(a->loop);
    free(a);
}
