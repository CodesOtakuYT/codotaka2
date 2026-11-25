# codotaka: design and internals

This document explains how codotaka works and why it is built the way it is. It is meant
for a human reader who wants to understand, modify or extend the code. For building and
running, see `README.md`; for the current to-do list and measurements, see `NOTES.md`.

---

## 1. Goals and philosophy

codotaka is a media/UI foundation for Linux desktops, written in Zig, rendering with
Vulkan 1.4 directly onto Wayland. Its first full application is a video player.

Three principles drive almost every decision:

1. **One modern baseline, no fallbacks.** The code requires recent Wayland protocols,
   a Vulkan 1.4 driver with several 2025-era extensions, Zig master and FFmpeg 9. In
   exchange it has no compatibility branches, so each subsystem has one code path that
   can be read top to bottom.
2. **GPU-first.** Anything that touches pixels runs on the GPU: decoding, color
   conversion, frame interpolation, even the quality evaluator's image comparison.
   The CPU orchestrates and touches only small results.
3. **Libraries, not a monolith.** Reusable pieces live in `lib/` with explicit
   allocators and `std.Io` where they do I/O or concurrency. The application in `src/`
   composes them.

---

## 2. Repository map

```
build.zig              module graph, shader compilation (glslc), executables
lib/
  geom/                rectangles in logical / buffer coordinates
  slot_map/            generational handles
  drm_sync/            linux-drm-syncobj timelines (explicit sync)
  dmabuf_feedback/     zwp_linux_dmabuf feedback parsing, format/modifier tranches
  wl/                  Wayland: display, surfaces, input, xkbcommon keyboard
  vk_core/             Vulkan instance/device, memory, buffers, images, descriptor
                       heaps, shader objects, frame ring, barriers, deletion queue
  vk_present/          presentation into dmabuf-backed wl_buffers (no swapchain)
  frame.zig            draw lists and views shared by renderer and scene
  scene/               damage-driven scene graph: windows, subsurface nodes, viewports
  text/                fonts, shaping, bidi, line breaking, glyph cache
  csd/                 client-side decorations drawn with Vulkan
  media/               FFmpeg Vulkan Video decoder, PipeWire audio output
src/
  main.zig             the app: demo windows or the player, event loop wiring
  EventLoop.zig        fd-driven loop (Wayland, buffer release, decoder wake-ups)
  Gpu.zig              per-GPU bundle: device, presenter, renderer
  Renderer.zig         draws everything: programs, video, interpolation, glyph atlas
  Atlas.zig            glyph atlas (host image copy uploads)
  player.zig           video view (frame pacing, A/V sync), OSD, input
  demo.zig             demo windows (triangle, text, subsurfaces)
  Flow.zig             optical-flow motion estimation (VK_NV_optical_flow)
  eval.zig, eval_main.zig   codotaka-eval, the offline interpolation quality tool
  known_issues.zig     upstream validation messages that are counted, not hidden
shaders/               GLSL 4.60 with descriptor_heap, buffer_reference, compute
```

---

## 3. Presentation: Wayland without a swapchain

### Why no VkSwapchainKHR
A Vulkan swapchain hides buffer allocation, format choice and synchronization behind
the driver's WSI layer. codotaka manages them itself to get:
- **Exact control over buffer formats and modifiers**, chosen from the compositor's
  dmabuf feedback tranches. The first tranche is usually the one that can be scanned
  out directly or composited cheapest.
- **Explicit synchronization** through `linux-drm-syncobj`: every buffer carries an
  acquire point (the GPU is done rendering it) and a release point (the compositor is
  done reading it). There is no implicit fencing and no guessing.
- **Subsurfaces as first-class render targets**: each scene node is a `wl_subsurface`
  with its own buffers, so parts of a window update independently, for example video
  underneath an on-screen display.

### How a frame is presented
1. `vk_present.SurfaceTarget` owns a small pool of buffers per surface. Each is a
   `vk_core.Image` with DRM-format-modifier tiling, exported as a dmabuf and wrapped in a
   `wl_buffer`.
2. To render, the presenter acquires a buffer whose release point has signalled, so the
   compositor no longer reads it. If none is free, that tree is skipped this frame
   ("busy"), never blocked.
3. All targets of a window tree are recorded into **one command buffer**, submitted once.
   Subsurfaces are all-or-nothing per tree, so a commit never shows mismatched content.
4. The submission signals the device timeline and a binary semaphore. That semaphore is
   exported as a sync_file and imported into the buffer's drm syncobj acquire point.
5. The surfaces are committed with damage regions; `wp_presentation` feedback reports
   when they actually reached the screen.

### Frame timing
`scene.FrameTime` predicts the next vsync from presentation feedback. Content asks
"wake me so that something is presented at time T" (`wakeToPresentAt`), which snaps to
the vsync grid. The video view uses this to pick frames for their predicted display
time rather than for "now".

### Color
Two modes: SDR (8-bit sRGB-encoded formats) and `--hdr`, which uses FP16 linear scRGB.
In scRGB, 1.0 = 80 cd/m² and reference white is 203 cd/m² (BT.2408); surfaces are tagged
with an image description. Translucent surfaces need premultiplied alpha in the space
the compositor blends in. For SDR that means gamma-encoded values, so shaders have a
specialization-constant output variant that encodes to gamma 2.2 and premultiplies in
that space (`shaders/output.glsl`, `vk_present/formats.zig`).

---

## 4. Vulkan model (`lib/vk_core`)

### Device baseline
`Device.create` requires, and fails without:
- Vulkan 1.4 core: timeline semaphores, buffer device address, scalar block layout,
  synchronization2, dynamic rendering, maintenance 5/6, host image copy.
- `VK_EXT_descriptor_heap` + `VK_KHR_shader_untyped_pointers`: shaders index the
  descriptor heaps directly through built-ins. There are no descriptor sets, layouts or
  binding mappings.
- `VK_EXT_shader_object`: no pipelines. All state is dynamic and set per draw.
- `VK_KHR_unified_image_layouts`: every image lives in `GENERAL`. Barriers only order
  memory, they never change layouts after the first use.
- `VK_KHR_internally_synchronized_queues`: any thread may submit, which matters for
  sharing the device with FFmpeg.
- `VK_KHR_robustness2` null descriptors.

Optional families, enabled on request:
- **Video decode** (H.264, H.265, AV1, VP9) on a dedicated queue family.
- **Optical flow** (`VK_NV_optical_flow`) on its own queue family, together with
  `VK_EXT_shader_atomic_float` for splatting.

### Descriptor heaps
`DescriptorHeaps` holds one resource heap and one sampler heap, bound once per command
buffer. Images get a slot index (`ImageSlot`); shaders declare
`layout(descriptor_heap) uniform texture2D textures[]` and index it with the slot passed
in push data. Buffers are not in the heap at all: shaders read them through
`buffer_reference` device addresses.

### Shader objects
`ShaderCache` registers graphics programs (vertex + fragment, with one fragment variant
per output encoding) and compute shaders. Binding is a single `vkCmdBindShadersEXT`. Push
data is written with `vkCmdPushDataEXT`; every program starts its push block with a
64-bit address for per-draw data.

### Frame ring and synchronization
`FrameRing` cycles through a few command buffers, each with a transient upload buffer
(a bump allocator in host-visible memory). Every submission signals the device timeline
with an increasing value. Resources are freed through `DeletionQueue` once the timeline
passes the value of their last use. Extra waits and signals (decoder semaphores, optical
flow) go through `FrameRing.Sync`.

---

## 5. Scene graph and rendering

`lib/scene` models a window as a tree of nodes (the root surface plus subsurfaces) with
**viewports** placed on them. Content objects implement two functions:
- `update(FrameTime) -> {dirty, next_wake_ns}` decides whether anything changed and
  when to be woken next.
- `draw(DrawContext, DrawList)` emits draws (`frame.Draw`: program id, push bytes, data
  bytes, vertex and instance counts).

Only dirty nodes are re-rendered, and only damaged regions are reported. A hidden OSD,
for example, costs nothing.

`src/Renderer.zig` turns draw lists into commands. Its programs:

| Program | Purpose |
|---|---|
| `triangle` | demo content |
| `decoration` | window decorations (title bar, buttons, shadows) |
| `text` | glyph quads from the atlas, premultiplied blending |
| `rect` | instanced SDF rounded rectangles (OSD panel, progress bar) |
| `video` | decoded frames: Y'CbCr → RGB, HDR handling, interpolation output |
| `luma` | optical-flow input extraction |
| `splat` (compute) | frame interpolation by forward splatting |

---

## 6. Text (`lib/text`)

- **fontconfig** finds fonts and fallbacks; **FreeType** rasterizes glyphs.
- **SheenBidi** resolves bidirectional runs (Unicode Bidirectional Algorithm).
- **HarfBuzz** shapes each run (ligatures, kerning, complex scripts).
- **libunibreak** finds line-break opportunities.
- Glyphs are cached CPU-side (`GlyphCache`) and uploaded to a GPU atlas with host image
  copy. That is a direct `memcpy` into the image, without a staging buffer or command
  buffer.
- Keyboard input goes through **xkbcommon** for layouts, compose and keysyms.

---

## 7. Media: video decoding (`lib/media`)

### FFmpeg on our own Vulkan device
FFmpeg's Vulkan hwaccel normally creates its own VkDevice. Instead, `HwDevice` hands
FFmpeg *our* device, queues and enabled extensions (`AVVulkanDeviceContext`), with
`queue_flags = INTERNALLY_SYNCHRONIZED`. FFmpeg decodes on our device's video queue, and
the decoded `VkImage`s are directly usable by our renderer, with no copies or exports.

The frames context is created in the `get_format` callback with
`MUTABLE_FORMAT | EXTENDED_USAGE` and `SAMPLED` usage, so each plane of the decoded NV12
(8-bit) or P010 (10-bit) image can be viewed separately. NVIDIA's decode output is
OPTIMAL-tiled only, so it can't be exported as a dmabuf for direct scanout. The video
shader samples the luma and chroma planes bindlessly and writes the converted color into
our presentation buffer: one GPU pass, zero CPU copies.

### Synchronization with FFmpeg
Each decoded frame carries FFmpeg's timeline semaphore and value. When the renderer uses
a frame, it:
1. takes FFmpeg's frame lock;
2. records a barrier to `GENERAL`;
3. makes its submission wait for `sem_value` and signal `sem_value + 1`;
4. unlocks after submitting.

FFmpeg then waits for our signal before reusing the image. Ordering is entirely on the GPU.

### Decoder structure
`Decoder` runs two `Io.concurrent` tasks:
- **Demux task:** reads packets, decodes and resamples audio into the audio ring, and
  queues compressed video packets (up to 512, which is cheap). Because audio is decoded
  here, a full video frame queue never starves audio.
- **Video task:** sends packets to the hardware decoder and pushes decoded frames into
  a small queue (6). That bounded queue is the backpressure.

An eventfd wakes the main loop when frames are queued.

### Seeking
A seek request packs a generation number and the target time into one atomic. The demux
task applies it: it seeks, flushes audio, starts a new audio segment, and sends a seek
marker down the packet queue. The video task tags every frame with the generation it is
actually decoding. The player drops frames of older generations and shows the first frame
at or after the target ("accurate seek": frames from the keyframe up to the target are
decoded but skipped).

### Looping
At end of file the demuxer seeks back to the start and offsets timestamps by the length of
the previous pass, so media time keeps increasing. The audio clock stays continuous
because it counts samples.

---

## 8. Media: audio and A/V sync

### Output
PipeWire's stream setup needs SPA format builders, which are C macros and inline
functions that Zig can't translate. So a ~100-line C shim (`pw_shim.c`) creates the
stream, and everything else is Zig. The realtime callback reads from a lock-free
single-producer/single-consumer ring (about 2 s of f32 stereo at 48 kHz). It never locks
or allocates.

### The audio master clock
On every callback, the audio thread publishes a pair through a seqlock: "media time X
will be *heard* at monotonic time T". T = now + the stream's total delay from
`pw_stream_get_time_n`, which includes the device buffer. On Bluetooth that is about 214 ms.

### Video follows audio
The video view computes the media time at the *predicted presentation time* of the next
vsync from that clock, and shows the newest frame due by then. Both sides use
`CLOCK_MONOTONIC`, so audio and display latency both cancel out. Measured result: mean
A/V error 3.3 ms and max 6.7 ms on a 75 Hz display, which is the vsync quantization floor.

Without audio, an anchor clock (first frame shown at T₀) drives playback instead.

### Pause and seek
- Clock samples published before a resume or seek are ignored, so a stale sample is
  never extrapolated across the gap.
- After a seek, audio stays paused until the decoder has buffered frames at the new
  position (pre-roll), so audio can't run ahead of video.
- The audio ring treats discarded pre-seek samples as free space. Otherwise a held
  audio stream could block the decoder forever.

---

## 9. The player UI

- **Video view:** letterboxed into the window; damage-driven (redrawn only when a new
  frame is due or interpolation changes the image).
- **OSD:** a translucent subsurface above the video's bottom edge, with a rounded panel,
  progress bar, time label and pause glyph. It appears on pointer motion, pause and seek,
  and hides after 2.5 s. Clicking the bar seeks.
- **Keys:** space, ←/→ (±5 s), Home, f (fullscreen), q/Esc, and i (interpolation mode).

---

## 10. Frame interpolation

Interpolation synthesizes in-between images so low-frame-rate video, such as 24 fps on a
75 Hz display, moves smoothly. It is optional (key `i`) and needs NVIDIA's optical-flow
accelerator.

### 10.1 Pipeline overview
For each frame pair (A shown now, B next):

```
graphics queue                    optical-flow queue                 graphics queue
──────────────                    ──────────────────                 ──────────────
luma(A), luma(B)       ─sem─►     coarse pass (½ res)                splat A and B forward
½-size luma(A), luma(B)           copy → hint image          ─sem─►  (compute, every vsync)
                                  full pass (hinted,                 normalize + display
                                  bidirectional, cost, global)       (video.frag)
                                  copy results → slot
```

### 10.2 Motion estimation (`src/Flow.zig`)
- **Input:** the luma plane rendered into an 8-bit image at most 1920 px wide (a multiple
  of 16), plus a half-size copy.
- **Coarse-to-fine:** a half-resolution pass runs first. Its 4×4-grid output has exactly
  the size of the full pass's 8×8 hint grid, so it is copied into the hint image. The full
  pass then searches around those hints, which roughly doubles the reachable motion
  beyond the hardware's ±64 px search range.
- **Full pass:** best-quality level, forward and backward vectors, a per-block cost
  (confidence), and a global (camera) motion vector.
- **Temporal hints:** the hardware reuses its previous result as a starting point. There
  is one session per pass, so it always sees consecutive pairs in order.
- **Prefetch:** results are copied into one of two slots. While pair (A, B) is on screen,
  pair (B, C) is already being estimated, so vectors are always ready on time.
- **Synchronization:** one timeline semaphore. Graphics signals "luma written",
  optical flow waits on it and signals "slot ready", and the frames that use the slot wait
  on that.

### 10.3 Driver facts learned the hard way
- A forward vector V at pixel x of the input frame means that pixel is at x + V in the
  reference frame (per the spec).
- Sampling `VK_FORMAT_R16G16_SFIXED5_NV` from a shader returned the raw fixed-point value,
  not value/32. The vectors are therefore copied into `R16G16_SINT` images and divided by
  32 in shaders.
- Mutable-format alias views of optical-flow outputs read garbage.
- An image can't be both an optical-flow output and a hint input; the copy between them
  is required.

### 10.4 Synthesis by forward softmax splatting (`shaders/splat.comp`)
Backward warping (asking "where did this output pixel come from?") can't decide which of
two overlapping objects is in front, which produces torn foreground fragments. codotaka
uses forward splatting instead (Niklaus & Liu, CVPR 2020):

1. Every pixel of A moves along its own A→B vector to `p + t·v`, and every pixel of B moves
   along its own B→A vector to `p + (1−t)·v`.
2. Each pixel adds its color to the four nearest output pixels of a float accumulator with
   atomics (color × weight, weight).
3. The weight is `time_weight × exp(z)` (time_weight favours the frame closer to t) with:
   - **brightness constancy:** the pixel's color matches what its vector points to in the
     other frame;
   - **forward-backward consistency:** going there and back returns to the start;
   - **motion contrast:** motion that differs from the camera's global motion is likely
     foreground.
   Where splats collide, the most plausible foreground dominates. Uncovered background only
   receives splats from the frame that shows it.
4. `video.frag` normalizes the accumulator (bilinear over covered texels) and falls back
   to a blend of A and B where nothing landed.

### 10.5 Debug views
- `i` cycles through: off → on → **show vectors** (hue = direction, brightness = speed)
  → **show luma** (the optical-flow input) → off.
- `CODOTAKA_FLOW_DUMP=1` logs raw vector statistics and the global vector.

---

## 11. Measuring quality: `codotaka-eval`

### Method
1. Decode a high-frame-rate video (e.g. 60 fps) and keep every Nth frame (N = 6 → 10 fps).
2. For each dropped frame, render through the real `Renderer` into offscreen FP16 images:
   - the real frame (truth);
   - repeat-nearest (what a player shows without interpolation);
   - a crossfade of the two kept frames;
   - our interpolation.
3. A compute shader (`metric.comp`) sums squared errors of gamma-encoded RGB per
   workgroup, so the CPU reads only 4 floats per frame, once per interval.
4. Scores are PSNR computed from the **mean squared error** over all frames. Averaging dB
   values would let static frames, which score near-infinite PSNR, dominate.
5. Intervals spanning a scene cut (endpoints differ by more than 12 dB PSNR) are excluded
   and counted, because no method can interpolate across a cut.

### Outputs
- A summary: mean and worst-frame PSNR per method.
- `--csv`: per-frame rows with interval, position t, endpoint difference and each method's
  PSNR.
- `--worst DIR`: heat maps of the worst frames (`heat.comp`). Each image shows the
  interpolated frame on the left and its error in red over the dimmed real frame on the right.

### Speed
300 intervals of 4K 60 fps H.264 take about 14 s in a release build, which is close to the
cost of decoding the frames.

### Current results (Big Buck Bunny 60–90 s, 60 → 10 fps)

| Method | PSNR | Worst frame |
|---|---|---|
| Repeat nearest | 27.48 dB | 16.38 dB |
| Crossfade | 28.89 dB | 18.60 dB |
| Interpolation | 31.66 dB | 19.80 dB |

Two findings:
- **Static or slow content:** interpolation is about 2 dB *worse* than a crossfade. The
  in-between frame is built at the estimation size (1920×1072) and resampled.
- **Large near-camera motion** is where the worst frames fail.

`NOTES.md` lists the planned fixes.

---

## 12. Validation, testing and debugging

- **Debug builds** enable the Khronos validation layer with synchronization validation.
  Messages go to `std.log` (scope `vk_validation`). Known upstream FFmpeg issues are
  reported once and then counted (`src/known_issues.zig`).
- `CODOTAKA_EXIT_AFTER=N` exits cleanly after N seconds, running the full teardown and
  leak check, which is useful for automated runs.
- `zig build test` runs library unit tests (geom, slot_map, drm_sync, dmabuf_feedback,
  scene).
- `codotaka-eval` is the regression test for interpolation quality.
- Profiling: `perf record -e cpu-clock:u` (no call graphs, since `perf_event_paranoid=2`).

---

## 13. Known limitations

- Linux + Wayland only; requires very recent drivers (developed on NVIDIA RTX 3050, KWin).
- Frame interpolation is NVIDIA-only, and quality is still below learned methods.
- The player polls every 5 ms during seek pre-roll, has no volume control, and drops the
  audio already in the device buffer on pause.
- FFmpeg's Vulkan decode triggers a few validation messages (upstream).

---

## 14. Extending the code

- **New draw type:** add a `Program`, write the shaders (push block starting with a
  `uint64_t` address), register it in `Renderer.create`, emit `frame.Draw`s from content.
- **New compute pass:** `ShaderCache.registerCompute`, bind with `bindCompute`, pass
  buffers by device address and images by heap slot, and order with
  `pipelineBarrier2` memory barriers. Layouts never change.
- **New scene content:** implement `update`/`draw`, add a node (translucent if needed)
  and a viewport, and place it.
- **New measurement:** extend `metric.comp` and the CSV columns in `eval.zig`. Keep it on
  the GPU.
