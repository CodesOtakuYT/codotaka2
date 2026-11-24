#version 450

layout(push_constant) uniform Push {
    float angle;
    float intensity;   // 1.0 = reference white
    float white_scale; // output value of reference white (1.0 SDR, 203/80 for scRGB)
} pc;

layout(location = 0) out vec3 v_color;

const vec2 positions[3] = vec2[](vec2(0.0, -0.6), vec2(0.52, 0.3), vec2(-0.52, 0.3));
const vec3 colors[3] = vec3[](vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));

void main() {
    float s = sin(pc.angle);
    float c = cos(pc.angle);
    vec2 p = positions[gl_VertexIndex];
    gl_Position = vec4(c * p.x - s * p.y, s * p.x + c * p.y, 0.0, 1.0);
    v_color = colors[gl_VertexIndex];
}
