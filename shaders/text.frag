#version 460
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Bindless: the bound descriptor heaps, indexed by slot (SPV_EXT_descriptor_heap).
layout(descriptor_heap) uniform texture2D textures[];
layout(descriptor_heap) uniform sampler samplers[];

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec2 size_px;
    float white_scale;
    float pad;
    uint atlas;
    uint sampler_slot;
    vec2 atlas_inv_size;
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    float coverage = texture(sampler2D(textures[nonuniformEXT(pc.atlas)], samplers[pc.sampler_slot]), v_uv).r;
    out_color = v_color * coverage * vec4(vec3(pc.white_scale), 1.0);
}
