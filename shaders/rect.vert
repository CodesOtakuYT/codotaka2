#version 460
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Instanced rounded rectangles read by device address (UI panels, bars, selections).
struct Rect {
    vec2 pos;    // top-left, viewport pixels
    vec2 size;   // pixels
    vec4 color;  // linear, premultiplied
    float radius;
};
layout(buffer_reference, scalar) readonly buffer Rects { Rect r[]; };

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec2 size_px;
    float white_scale;
} pc;

layout(location = 0) out vec2 v_local;        // pixels from the rect center
layout(location = 1) flat out vec2 v_half;
layout(location = 2) flat out float v_radius;
layout(location = 3) flat out vec4 v_color;

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main() {
    Rect r = Rects(pc.data).r[gl_InstanceIndex];
    vec2 c = corners[gl_VertexIndex];
    // One pixel of slack around the rect for antialiasing.
    vec2 px = r.pos - 1.0 + c * (r.size + 2.0);
    gl_Position = vec4(px / pc.size_px * 2.0 - 1.0, 0.0, 1.0);
    v_local = px - (r.pos + r.size * 0.5);
    v_half = r.size * 0.5;
    v_radius = min(r.radius, min(v_half.x, v_half.y));
    v_color = r.color * vec4(vec3(pc.white_scale), 1.0);
}
