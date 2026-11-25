#version 460
#extension GL_EXT_descriptor_heap : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Optical-flow input: the frame's luma plane, resampled to the estimation size.
layout(descriptor_heap) uniform texture2D textures[];
layout(descriptor_heap) uniform sampler samplers[];

layout(push_constant, scalar) uniform Push {
    uint64_t data;
    vec4 dst;
    vec2 uv_max;
    uint luma, chroma, smp;
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_luma;

void main() {
    out_luma = vec4(texture(sampler2D(textures[nonuniformEXT(pc.luma)], samplers[pc.smp]), v_uv).r);
}
