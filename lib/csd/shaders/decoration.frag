#version 450
#extension GL_GOOGLE_include_directive : require

// Client-side title bar: background, title text and minimize/maximize/close buttons,
// all procedural so it is resolution independent under fractional scaling.

#include "font8x8.glsl" // from lib/bitmap_font (include path set by the build)

layout(push_constant) uniform Push {
    vec2 size;         // view size in buffer pixels
    float scale;       // buffer pixels per logical pixel
    float white_scale; // output value of reference white
    uint hover;        // 0 none, 1 minimize, 2 maximize, 3 close
    uint flags;        // bit 0 focused, bit 1 maximized, bit 2 pressed
    uint title_len;
    uint pad;
    uint chars[16];    // up to 64 ASCII characters, 4 per uint
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

vec3 srgb(vec3 c) { return pow(c, vec3(2.2)); }

float segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

float boxOutline(vec2 p, vec2 center, vec2 half_size) {
    vec2 d = abs(p - center) - half_size;
    return abs(length(max(d, 0.0)) + min(max(d.x, d.y), 0.0));
}

uint charAt(uint i) {
    return (pc.chars[i >> 2] >> ((i & 3u) * 8u)) & 0xffu;
}

float glyph(vec2 q, vec2 origin, float px) {
    vec2 local = (q - origin) / px; // in font pixels
    if (local.y < 0.0 || local.y >= 8.0 || local.x < 0.0) return 0.0;
    uint col = uint(local.x) / 8u;
    if (col >= pc.title_len) return 0.0;
    uint ch = charAt(col);
    if (ch < 32u || ch > 126u) ch = 63u; // '?'
    uvec2 g = FONT8X8[ch - 32u];
    uint row = uint(local.y);
    uint bits = (row < 4u ? g.x : g.y) >> ((row & 3u) * 8u);
    return float((bits >> (uint(local.x) & 7u)) & 1u);
}

void main() {
    bool focused = (pc.flags & 1u) != 0u;
    bool maximized = (pc.flags & 2u) != 0u;
    bool pressed = (pc.flags & 4u) != 0u;

    vec2 q = v_uv * pc.size / pc.scale; // logical pixels
    float w = pc.size.x / pc.scale;
    float h = pc.size.y / pc.scale;
    float aa = 1.0 / pc.scale;          // one buffer pixel, in logical units

    vec3 color = focused ? srgb(vec3(0.17, 0.17, 0.20)) : srgb(vec3(0.13, 0.13, 0.15));
    vec3 fg = focused ? srgb(vec3(0.90)) : srgb(vec3(0.55));

    // Buttons, right to left: close, maximize, minimize. Each is h wide.
    uint button = 0u;
    if (q.x >= w - h) button = 3u;
    else if (q.x >= w - 2.0 * h) button = 2u;
    else if (q.x >= w - 3.0 * h) button = 1u;

    if (button != 0u) {
        float right = w - float(3u - button) * h;
        vec2 c = vec2(right - h * 0.5, h * 0.5);
        if (button == pc.hover) {
            vec3 hover_bg = button == 3u ? srgb(vec3(0.77, 0.17, 0.11)) : srgb(vec3(1.0)) * 0.08 + color;
            if (pressed) hover_bg *= 0.8;
            color = hover_bg;
        }
        float r = 5.0; // icon half-size
        float d;
        if (button == 3u) {
            d = min(segment(q, c - r, c + r), segment(q, c + vec2(r, -r), c + vec2(-r, r)));
        } else if (button == 2u) {
            if (maximized) {
                d = min(boxOutline(q, c + vec2(-1.5, 1.5), vec2(r - 1.5)),
                        max(boxOutline(q, c + vec2(1.5, -1.5), vec2(r - 1.5)),
                            -(max(abs(q.x - c.x + 1.5), abs(q.y - c.y - 1.5)) - (r - 1.5))));
            } else {
                d = boxOutline(q, c, vec2(r));
            }
        } else {
            d = segment(q, c + vec2(-r, 0.0), c + vec2(r, 0.0));
        }
        vec3 icon = (button == 3u && button == pc.hover) ? srgb(vec3(1.0)) : fg;
        color = mix(color, icon, 1.0 - smoothstep(0.5, 0.5 + aa, d));
    } else {
        // Title text, 8x8 font at 2 logical px per font pixel, vertically centered.
        float px = max(1.0, floor(2.0 * pc.scale + 0.5)) / pc.scale;
        vec2 origin = vec2(10.0, floor((h - 8.0 * px) * 0.5 * pc.scale) / pc.scale);
        color = mix(color, fg, glyph(q, origin, px));
    }

    // 1px separator at the bottom.
    if (q.y >= h - aa) color *= 0.5;

    out_color = vec4(color * pc.white_scale, 1.0);
}
