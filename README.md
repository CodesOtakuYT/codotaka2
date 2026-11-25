# codotaka

A cutting-edge Zig + Wayland + Vulkan 1.4 media/UI foundation: a zero-copy video player
with audio, seeking, an on-screen display and optional optical-flow frame interpolation.

## Requirements

- Zig master (developed with `0.18.0-dev.1279`), at `~/.local/bin/zig`
- Linux, a Wayland compositor with `linux-dmabuf`, `linux-drm-syncobj`, `wp_presentation`
  (developed on KWin)
- Vulkan 1.4 driver with `VK_EXT_descriptor_heap`, `VK_KHR_shader_untyped_pointers`,
  `VK_EXT_shader_object`, `VK_KHR_unified_image_layouts`,
  `VK_KHR_internally_synchronized_queues`, `VK_KHR_robustness2` (developed on NVIDIA RTX 3050)
- FFmpeg 9.1 (libavformat/libavcodec/libavutil/libswresample, Vulkan Video), PipeWire 1.6,
  HarfBuzz, FreeType, fontconfig, libunibreak, xkbcommon, `glslc`
- Optional: `VK_NV_optical_flow` + `VK_EXT_shader_atomic_float` for frame interpolation

There are no fallback paths: this targets one modern baseline.

## Build and run

```sh
~/.local/bin/zig build                      # debug (validation layer on)
~/.local/bin/zig build -Doptimize=ReleaseFast
~/.local/bin/zig build test

./zig-out/bin/codotaka [--hdr] [n]          # demo windows
./zig-out/bin/codotaka [--hdr] <video>      # player
./zig-out/bin/codotaka-eval <60fps-video> [--step 6] [--intervals 300] [--start 60] \
    [--csv out.csv] [--worst dir/]          # offline interpolation quality tool
```

Player keys: `space` pause, `←/→` seek ±5 s, `Home` start, `f` fullscreen, `q`/`Esc` quit,
`i` cycles interpolation off → on → show vectors → show luma. Clicking the OSD bar seeks.

Environment (debug/testing): `CODOTAKA_EXIT_AFTER=N` (clean exit + leak check),
`CODOTAKA_INTERPOLATION=on|show_vectors|show_luma`, `CODOTAKA_FLOW_DUMP=1`.

## Layout

```
lib/geom, slot_map         small utilities
lib/drm_sync, dmabuf_feedback, wl   Wayland: surfaces, explicit sync, tranche-aware formats
lib/vk_core                 instance/device, descriptor heaps, shader objects, frame ring
lib/vk_present              dmabuf + drm-syncobj presentation (no VkSwapchainKHR)
lib/frame, scene            draw lists, damage-driven scene graph with subsurfaces
lib/text                    HarfBuzz/FreeType/SheenBidi/libunibreak layout + glyph cache
lib/csd                     client-side decorations rendered with Vulkan
lib/media                   FFmpeg Vulkan Video decoder on our VkDevice, PipeWire audio
src/                        app: Renderer, player, demo, Flow (optical flow), eval tool
shaders/                    GLSL (descriptor_heap, buffer_reference, compute)
```

See `NOTES.md` for design decisions, current state and next steps.
