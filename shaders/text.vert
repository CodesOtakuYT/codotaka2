#version 460
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// One instance per glyph quad, read by device address (no vertex buffers).
struct Glyph {
    vec2 pos;   // top-left, viewport pixels
    vec2 size;  // pixels
    vec2 uv0;   // atlas texels
    vec2 uv1;
    vec4 color; // linear, premultiplied
};
layout(buffer_reference, scalar) readonly buffer Glyphs { Glyph g[]; };

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec2 size_px;
    float white_scale;
    float pad;
    uint atlas;
    uint sampler_slot;
    vec2 atlas_inv_size;
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    Glyph g = Glyphs(pc.data).g[gl_InstanceIndex];
    vec2 corner = corners[gl_VertexIndex];
    vec2 px = g.pos + corner * g.size;
    gl_Position = vec4(px / pc.size_px * 2.0 - 1.0, 0.0, 1.0);
    v_uv = mix(g.uv0, g.uv1, corner) * pc.atlas_inv_size;
    v_color = g.color;
}
