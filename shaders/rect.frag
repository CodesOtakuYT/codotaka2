#version 460
#extension GL_GOOGLE_include_directive : require
#include "output.glsl"

layout(location = 0) in vec2 v_local;
layout(location = 1) flat in vec2 v_half;
layout(location = 2) flat in float v_radius;
layout(location = 3) flat in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    vec2 q = abs(v_local) - v_half + v_radius;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - v_radius; // signed distance
    float coverage = clamp(0.5 - d, 0.0, 1.0);
    out_color = encodeOutput(v_color * coverage);
}
