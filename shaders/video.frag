#version 460
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_samplerless_texture_functions : require
#extension GL_EXT_buffer_reference : require
#extension GL_GOOGLE_include_directive : require
#include "output.glsl"
#include "video_common.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// Normalized splat color at accumulator texel i (weight 0 where nothing landed).
vec4 splatAt(Accum acc, ivec2 i) {
    ivec2 size = ivec2(pc.flow_size);
    if (any(lessThan(i, ivec2(0))) || any(greaterThanEqual(i, size))) return vec4(0);
    vec4 a = acc.v[i.y * size.x + i.x];
    return a.w > 1e-6 ? vec4(a.rgb / a.w, 1.0) : vec4(0);
}

void main() {
    vec2 uv = v_uv;
    if (pc.mode == 0u) {
        out_color = encodeOutput(vec4(shade(uv, pc.luma, pc.chroma), 1.0));
        return;
    }
    if (pc.mode == 3u) {
        float l = texture(sampler2D(textures[nonuniformEXT(pc.debug_luma)], samplers[pc.smp]), uv / pc.uv_max).r;
        out_color = encodeOutput(vec4(vec3(l), 1.0));
        return;
    }
    vec2 x = uv / pc.uv_max * pc.flow_size;
    if (pc.mode == 2u) {
        // Forward vectors (B -> A): hue = direction, brightness = speed.
        vec2 m = flowAt(pc.vectors, x);
        float mag = clamp(length(m) / 8.0, 0.0, 1.0);
        vec3 dir = 0.5 + 0.5 * vec3(m.x, m.y, -m.x) / max(length(m), 1e-3);
        out_color = encodeOutput(vec4(mix(frameA(x) * 0.2, dir * pc.white_scale, mag), 1.0));
        return;
    }
    // The in-between frame, splatted by splat.comp: bilinear over covered texels.
    Accum acc = Accum(pc.data);
    vec2 q = x - 0.5;
    ivec2 i0 = ivec2(floor(q));
    vec2 f = fract(q);
    vec4 c = splatAt(acc, i0) * (1.0 - f.x) * (1.0 - f.y) + splatAt(acc, i0 + ivec2(1, 0)) * f.x * (1.0 - f.y)
           + splatAt(acc, i0 + ivec2(0, 1)) * (1.0 - f.x) * f.y + splatAt(acc, i0 + ivec2(1, 1)) * f.x * f.y;
    // Nothing landed here (rare: both frames' splats missed): blend in place.
    vec3 hole = mix(frameA(x), frameB(x), pc.alpha);
    vec3 col = c.w > 1e-3 ? c.rgb / c.w : hole;
    out_color = encodeOutput(vec4(col, 1.0));
}
