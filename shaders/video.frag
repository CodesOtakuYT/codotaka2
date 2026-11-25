#version 460
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_samplerless_texture_functions : require
#extension GL_GOOGLE_include_directive : require
#include "output.glsl"

// Zero-copy video: the decoder's VkImage planes are sampled straight from the heap.
layout(descriptor_heap) uniform texture2D textures[];
layout(descriptor_heap) uniform itexture2D itextures[];
layout(descriptor_heap) uniform utexture2D utextures[];
layout(descriptor_heap) uniform sampler samplers[];

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec4 dst;
    vec2 uv_max;
    uint luma, chroma, smp;
    uint matrix, transfer, primaries, full_range, bit_depth, output_hdr;
    float white_scale;
    float peak;
    // Motion-compensated interpolation between this frame (A) and the next (B).
    uint mode;                // 0 = A only, 1 = interpolate, 2 = show motion vectors
    uint luma_b, chroma_b;
    uint vectors, cost;       // flow from B to A, one vector per grid block (S10.5 pixels)
    float alpha;              // 0 = A, 1 = B
    vec2 flow_size;           // estimation size in pixels
    vec2 grid_size;           // vector image size in blocks
    uint debug_luma;          // estimation input (mode 3)
    uint back_vectors;        // flow from A to B
    uint global_flow;         // one B -> A vector for the whole frame (camera motion)
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const int GRID = 4; // Flow.grid
const float ref_white_nits = 203.0; // BT.2408

vec3 pq_eotf(vec3 e) { // -> nits
    const float m1 = 2610.0 / 16384.0, m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0, c2 = 2413.0 / 4096.0 * 32.0, c3 = 2392.0 / 4096.0 * 32.0;
    vec3 p = pow(max(e, 0.0), vec3(1.0 / m2));
    return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), vec3(1.0 / m1));
}

vec3 hlg_inverse_oetf(vec3 e) { // -> scene linear [0, 1]
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    return mix(e * e / 3.0, (exp((e - c) / a) + b) / 12.0, step(0.5, e));
}

// Linear output color of the frame with planes (luma, chroma) at uv.
vec3 shade(vec2 uv, uint luma, uint chroma) {
    float y = texture(sampler2D(textures[nonuniformEXT(luma)], samplers[pc.smp]), uv).r;
    vec2 cbcr = texture(sampler2D(textures[nonuniformEXT(chroma)], samplers[pc.smp]), uv).rg;

    // Range expansion (normalized samples; limited range scales with bit depth).
    float maxv = exp2(float(pc.bit_depth)) - 1.0;
    float s = exp2(float(pc.bit_depth) - 8.0);
    if (pc.full_range != 0) {
        cbcr -= 128.0 * s / maxv;
    } else {
        y = (y * maxv - 16.0 * s) / (219.0 * s);
        cbcr = (cbcr * maxv - 128.0 * s) / (224.0 * s);
    }

    // Y'CbCr -> R'G'B'.
    vec2 k = pc.matrix == 2u ? vec2(0.2627, 0.0593) : pc.matrix == 1u ? vec2(0.2126, 0.0722) : vec2(0.299, 0.114);
    float r = y + 2.0 * (1.0 - k.x) * cbcr.y;
    float b = y + 2.0 * (1.0 - k.y) * cbcr.x;
    float g = (y - k.x * r - k.y * b) / (1.0 - k.x - k.y);
    vec3 rgb = clamp(vec3(r, g, b), 0.0, 1.0);

    // Linearize, relative to reference white (1.0 = 203 cd/m²).
    vec3 lin;
    if (pc.transfer == 1u) {
        lin = pq_eotf(rgb) / ref_white_nits;
    } else if (pc.transfer == 2u) {
        vec3 scene = hlg_inverse_oetf(rgb);
        float ys = dot(scene, vec3(0.2627, 0.6780, 0.0593));
        lin = 1000.0 * pow(max(ys, 1e-6), 0.2) * scene / ref_white_nits; // OOTF at 1000 cd/m²
    } else {
        lin = pow(rgb, vec3(2.4)); // BT.1886
    }

    // BT.2020 -> BT.709 primaries (scRGB keeps out-of-gamut colors as negative values).
    if (pc.primaries == 1u) {
        lin = mat3(1.6605, -0.1246, -0.0182,
                   -0.5876, 1.1329, -0.1006,
                   -0.0728, -0.0083, 1.1187) * lin;
    }

    if (pc.output_hdr != 0) return lin * pc.white_scale;
    // SDR target: tone map HDR content (extended Reinhard on luminance), then clip.
    if (pc.transfer != 0u) {
        float l = dot(lin, vec3(0.2126, 0.7152, 0.0722));
        float mapped = l * (1.0 + l / (pc.peak * pc.peak)) / (1.0 + l);
        lin *= mapped / max(l, 1e-6);
    }
    return clamp(lin, 0.0, 1.0) * pc.white_scale;
}

vec2 vectorAt(uint field, ivec2 b) {
    b = clamp(b, ivec2(0), ivec2(pc.grid_size) - 1);
    return vec2(texelFetch(itextures[nonuniformEXT(field)], b, 0).rg) / 32.0; // S10.5
}

// Bilinear vector field at estimation-pixel position p.
vec2 flowAt(uint field, vec2 p) {
    vec2 g = p / float(GRID) - 0.5;
    ivec2 b0 = ivec2(floor(g));
    vec2 t = fract(g);
    return mix(mix(vectorAt(field, b0), vectorAt(field, b0 + ivec2(1, 0)), t.x),
               mix(vectorAt(field, b0 + ivec2(0, 1)), vectorAt(field, b0 + ivec2(1, 1)), t.x), t.y);
}

float costAt(vec2 p) {
    ivec2 b = clamp(ivec2(p / float(GRID)), ivec2(0), ivec2(pc.grid_size) - 1);
    return float(texelFetch(utextures[nonuniformEXT(pc.cost)], b, 0).r);
}

// Estimation pixels -> texture coordinates of the decoded frames.
vec2 toUv(vec2 px) { return px / pc.flow_size * pc.uv_max; }

vec3 frameA(vec2 px) { return shade(toUv(px), pc.luma, pc.chroma); }
vec3 frameB(vec2 px) { return shade(toUv(px), pc.luma_b, pc.chroma_b); }

float colorDiff(vec3 x, vec3 y) {
    vec3 d = abs(x - y) / max(pc.white_scale, 1e-3);
    return max(d.r, max(d.g, d.b));
}

// One motion hypothesis for the output pixel: where its content is in A and in B.
struct Candidate { vec3 a, b; float weight; vec2 motion; };

// How much a hypothesis is believed: both frames must show the same content there, and
// it must explain them clearly better than no motion (flat areas produce noise vectors).
float believe(vec3 a, vec3 b, float still_diff) {
    float d = colorDiff(a, b);
    return (1.0 - smoothstep(0.03, 0.10, d)) * smoothstep(0.005, 0.03, still_diff - d);
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
    float t = pc.alpha;
    vec2 x = uv / pc.uv_max * pc.flow_size;
    vec3 still_a = frameA(x);
    vec3 still_b = frameB(x);
    float still_diff = colorDiff(still_a, still_b);

    // Trajectory anchored in B: B's pixel xb (vector f: B -> A) is at xb + (1 - t) f at
    // time t. Solve xb + (1 - t) F(xb) = x by fixed-point iteration (each frame uses its
    // own field, so object edges don't borrow the neighbour's motion).
    vec2 xb = x;
    for (int i = 0; i < 4; i++) xb = x - (1.0 - t) * flowAt(pc.vectors, xb);
    vec2 f = flowAt(pc.vectors, xb);
    Candidate cb = Candidate(frameA(xb + f), frameB(xb), 0.0, -f);
    float fb_b = length(f + flowAt(pc.back_vectors, xb + f));
    cb.weight = believe(cb.a, cb.b, still_diff) * (1.0 - smoothstep(0.75, 2.5, fb_b))
              * (1.0 - smoothstep(64.0, 200.0, costAt(xb)));

    // Trajectory anchored in A (vector g: A -> B): xa + t G(xa) = x.
    vec2 xa = x;
    for (int i = 0; i < 4; i++) xa = x - t * flowAt(pc.back_vectors, xa);
    vec2 g = flowAt(pc.back_vectors, xa);
    Candidate ca = Candidate(frameA(xa), frameB(xa + g), 0.0, g);
    float fb_a = length(g + flowAt(pc.vectors, xa + g));
    ca.weight = believe(ca.a, ca.b, still_diff) * (1.0 - smoothstep(0.75, 2.5, fb_a));

    // Camera motion, for areas where local vectors failed (e.g. motion beyond the search).
    vec2 gf = vectorAt(pc.global_flow, ivec2(0));
    vec2 xg = x - (1.0 - t) * gf;
    Candidate cg = Candidate(frameA(xg + gf), frameB(xg), 0.0, -gf);
    cg.weight = believe(cg.a, cg.b, still_diff) * (1.0 - max(cb.weight, ca.weight)) * 0.5;

    // Unchanged content: the plain blend is exact.
    float w_still = 1.0 - smoothstep(0.01, 0.04, still_diff);
    // Occlusion (content visible in only one frame, no hypothesis holds): take it from one
    // frame along that frame's own trajectory instead of ghosting both.
    vec3 occluded = t < 0.5 ? ca.a : cb.b;
    float w_occ = 0.02;

    vec3 col = cb.weight * mix(cb.a, cb.b, t) + ca.weight * mix(ca.a, ca.b, t) + cg.weight * mix(cg.a, cg.b, t)
             + w_still * mix(still_a, still_b, t) + w_occ * occluded;
    float total = cb.weight + ca.weight + cg.weight + w_still + w_occ;

    if (pc.mode == 2u) {
        // Motion as used (B -> A direction): hue = direction, brightness = speed.
        vec2 m = (cb.weight * cb.motion + ca.weight * ca.motion + cg.weight * cg.motion) / total;
        float mag = clamp(length(m) / 8.0, 0.0, 1.0);
        vec3 dir = 0.5 + 0.5 * vec3(m.x, m.y, -m.x) / max(length(m), 1e-3);
        out_color = encodeOutput(vec4(mix(still_a * 0.2, dir * pc.white_scale, mag), 1.0));
        return;
    }
    out_color = encodeOutput(vec4(col / total, 1.0));
}
