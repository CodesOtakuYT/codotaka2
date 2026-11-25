#version 460
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

layout(push_constant, scalar) uniform Push {
    uint64_t data;    // unused
    vec4 dst;         // destination rect in NDC (x0, y0, x1, y1)
    vec2 uv_max;      // visible / coded size (crop of the decoder's padded pool image)
    uint luma, chroma, smp;
    uint matrix, transfer, primaries, full_range, bit_depth, output_hdr;
    float white_scale;
    float peak;       // content peak, relative to reference white (HDR tone mapping)
    uint mode, luma_b, chroma_b, vectors, cost;
    float alpha;
    vec2 flow_size, grid_size;
    uint debug_luma;
    uint back_vectors;
    uint global_flow;
    vec3 splat_z;
} pc;

layout(location = 0) out vec2 v_uv;

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    vec2 c = corners[gl_VertexIndex];
    gl_Position = vec4(mix(pc.dst.xy, pc.dst.zw, c), 0.0, 1.0);
    v_uv = c * pc.uv_max;
}
