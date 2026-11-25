#version 460
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_GOOGLE_include_directive : require
#include "output.glsl"

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    float angle;
    float intensity;
    float white_scale;
} pc;

layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    // Linear output; SRGB formats encode on store, scRGB (FP16) stays linear.
    out_color = encodeOutput(vec4(v_color * pc.intensity * pc.white_scale, 1.0));
}
