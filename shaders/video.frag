#version 460
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Zero-copy video: the decoder's VkImage planes are sampled straight from the heap.
layout(descriptor_heap) uniform texture2D textures[];
layout(descriptor_heap) uniform sampler samplers[];

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec4 dst;
    vec2 uv_max;
    uint luma, chroma, smp;
    uint matrix, transfer, primaries, full_range, bit_depth, output_hdr;
    float white_scale;
    float peak;
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

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

void main() {
    vec2 uv = v_uv;
    float y = texture(sampler2D(textures[nonuniformEXT(pc.luma)], samplers[pc.smp]), uv).r;
    vec2 cbcr = texture(sampler2D(textures[nonuniformEXT(pc.chroma)], samplers[pc.smp]), uv).rg;

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

    if (pc.output_hdr != 0) {
        out_color = vec4(lin * pc.white_scale, 1.0);
    } else {
        // SDR target: tone map HDR content (extended Reinhard on luminance), then clip.
        if (pc.transfer != 0u) {
            float l = dot(lin, vec3(0.2126, 0.7152, 0.0722));
            float mapped = l * (1.0 + l / (pc.peak * pc.peak)) / (1.0 + l);
            lin *= mapped / max(l, 1e-6);
        }
        out_color = vec4(clamp(lin, 0.0, 1.0) * pc.white_scale, 1.0);
    }
}
