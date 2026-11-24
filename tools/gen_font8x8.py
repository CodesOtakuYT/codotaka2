#!/usr/bin/env python3
"""Generates lib/bitmap_font/font8x8.glsl from font8x8_basic.h
(https://github.com/dhepper/font8x8, public domain, based on IBM VGA fonts).

Usage: tools/gen_font8x8.py font8x8_basic.h > lib/bitmap_font/font8x8.glsl
"""
import re
import sys

src = open(sys.argv[1]).read()
rows = re.findall(r'\{\s*((?:0x[0-9A-Fa-f]{2},?\s*){8})\}', src)
assert len(rows) == 128, len(rows)
print("// Generated from font8x8_basic.h by Daniel Hepper (public domain, based on IBM VGA fonts).")
print("// Glyphs U+0020..U+007E. Row r is byte (r % 4) of component r / 4; bit 0 is the leftmost pixel.")
print("const uvec2 FONT8X8[95] = uvec2[](")
items = []
for cp in range(32, 127):
    b = [int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]{2}', rows[cp])]
    lo = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
    hi = b[4] | b[5] << 8 | b[6] << 16 | b[7] << 24
    items.append(f"    uvec2(0x{lo:08x}u, 0x{hi:08x}u)")
print(",\n".join(items))
print(");")
