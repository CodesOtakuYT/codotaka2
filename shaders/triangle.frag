#version 450

layout(push_constant) uniform Push {
    float angle;
    float intensity;
    float white_scale;
} pc;

layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    // Linear output; SRGB formats encode on store, scRGB (FP16) stays linear.
    out_color = vec4(v_color * pc.intensity * pc.white_scale, 1.0);
}
