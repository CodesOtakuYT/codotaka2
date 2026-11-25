// Final output encoding, chosen per target format via specialization constant 0
// (see vk_present.formats.Encode). Input is premultiplied linear color.
layout(constant_id = 0) const uint OUTPUT_ENCODE = 0u;

vec4 encodeOutput(vec4 c) {
    if (OUTPUT_ENCODE == 1u) {
        // Translucent SDR (UNORM): gamma 2.2, premultiplied in encoded ("electrical") space,
        // which is what the compositor blends with.
        if (c.a <= 0.0) return vec4(0.0);
        vec3 straight = max(c.rgb / c.a, 0.0);
        return vec4(pow(straight, vec3(1.0 / 2.2)) * c.a, c.a);
    }
    return c;
}
