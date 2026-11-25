# Development notes (handoff context)

Read this first when resuming work. User preferences and decisions are binding.

## User preferences
- Cutting-edge only, no fallbacks ("just me"). Zig master at `~/.local/bin/zig`
  (never the system zig 0.17). vulkan-zig master.
- GPU-first: pixel-scale work goes on the GPU; the CPU only touches small results.
- Tools (e.g. `codotaka-eval`) are first-class: they dogfood the stack and ship.
- Independent libraries under `lib/`, allocator- and `std.Io`-aware APIs.
- Commit with `git -c user.name=codotaku -c user.email=codotaku@localhost commit`.
- Never inject keys into the desktop unless the player has focus (`/tmp/opencode/uinput_*.py`
  typed into the user's terminal once). Prefer env vars and the offline eval tool.
- Long-term goal: Helix/Kakoune-style modal editor, one window with splits, monospace
  grid + optional ligatures, HarfBuzz/FreeType/SheenBidi/libunibreak, xkbcommon.

## Architecture decisions
- Presentation: raw dmabuf + linux-drm-syncobj (no VkSwapchainKHR), tranche-aware,
  timeline semaphores, wp_presentation-predicted frame times (`FrameTime.wakeToPresentAt`).
- Vulkan: descriptor heaps via untyped pointers (`layout(descriptor_heap)`), shader
  objects (graphics pairs + compute), unified image layouts (GENERAL everywhere),
  internally synchronized queues, host image copy, push data via `pushDataEXT`.
- Translucent subsurfaces: alpha formats; SDR UNORM variant premultiplies in gamma-2.2
  space (specialization constant 0 = output encoding, `shaders/output.glsl`).
- Video: FFmpeg hw device wraps our VkDevice; decode on queue family 3; NVIDIA decode
  output is OPTIMAL only, so frames are sampled bindlessly (NV12/P010 planes) — zero copy.
  Known upstream FFmpeg validation issues are counted (`src/known_issues.zig`).
- Decoder: demux+audio task and video task (`Io.concurrent`), compressed packet queue;
  seeks are generation-tagged (generation packed with the target in one atomic).
- Audio: PipeWire via `lib/media/pw_shim.c`; f32 stereo 48 kHz via swresample; SPSC ring;
  audio is the master clock (seqlock: heard_at_ns, pts), latency-compensated.
  Pause/seek: stale clock samples rejected; audio held during seek pre-roll.

## Frame interpolation (VK_NV_optical_flow), state as of commit ad9990e + eval tool
- `src/Flow.zig`: luma at ≤1920 wide (multiple of 16) + half-size; coarse pass at half
  resolution whose 4×4 output is copied into the full pass's 8×8 hint image; full pass:
  slow perf level, bidirectional, cost, global flow. One session per pass (temporal hints
  see consecutive pairs); results copied into 2 prefetch slots (next pair estimated ahead).
- Driver quirks found: sampling `R16G16_SFIXED5_NV` returns unscaled values → vectors are
  copied to `R16G16_SINT` and divided by 32 in shaders. An image can't be both OF output
  and hint (separate hint image + copy). Mutable-format alias views of OF outputs = garbage.
- `shaders/splat.comp`: forward softmax splatting (Niklaus & Liu 2020) of A and B into a
  float accumulator (atomics), z = brightness constancy + fb consistency + motion distinct
  from global flow; `video.frag` normalizes it. Built at the estimation size.
- Spec: forward vector at input pixel x means it is at x+V in the reference frame.

## Evaluation tool: `codotaka-eval` (src/eval.zig, src/eval_main.zig)
- Drops frames from 60 fps video (step 6 → 10 fps), renders truth / A / B / ours into
  offscreen FP16 images via the real Renderer; `shaders/metric.comp` sums squared errors
  on the GPU; `shaders/heat.comp` writes heat maps (PPM: left ours, right error) of the
  worst frames; per-frame CSV. 300 intervals of BBB in ~14 s (release).
- Baseline (BBB 60–90 s, step 6, 1460 frames, 8 cut intervals excluded at 12 dB):
  nearest 27.48 dB, crossfade 28.89 dB, ours 31.66 dB (worst 19.80).
- Breakdown by endpoint difference: on near-static content (>30 dB) ours is 2.2 dB WORSE
  than crossfade (490 frames); gains +1.9…+3.2 dB elsewhere; 384/1460 frames worse.
- Heat map of the worst frame (interval 110, k=3): the moving bunny's face/body is
  smeared and torn (large motion of a near-camera object), background fine.

## Next steps (in order)
1. Fix the static-content regression: splat result is built at 1920×1072 (estimation
   size) and resampled to the frame → softness + sub-pixel shift. Build the in-between
   frame at full resolution (use low-res motion only), and/or fall back to the crossfade
   where motion is ~0. Measure with codotaka-eval after every change.
2. Large near-camera motion (bunny face): tune splat z weights; try 2×2 grid; check
   whether vectors hit the search limit (FLOW_DUMP); consider 3-level hints.
3. Learned refinement: RTX 3050 has VK_NV_cooperative_matrix2 (reductions, per-element
   ops, conversions, bf16) — a small RIFE-style network in our own compute shaders.
4. Player leftovers: 5 ms polling during seek/pre-roll (eventfd from audio thread), volume,
   audio lost on pause (~214 ms BT buffer), OSD text slightly high.
5. Then: the editor roadmap.

## Useful commands
- Debug run + validation: `CODOTAKA_EXIT_AFTER=6 ./zig-out/bin/codotaka <file>`
- Release: `~/.local/bin/zig build -Doptimize=ReleaseFast -p /tmp/opencode/rel`
- Test media: `~/Videos/codotaka-test/` (h264/hevc/av1/vp9, `*_audio.*`,
  `bbb_10fps_1080p.mp4`), `~/Downloads/bbb_sunflower_native_60fps_normal.mp4` (4K 60p).
- Screenshots: `spectacle -b -n -a -o f.png` (captures the focused window; unreliable when
  the user is active — prefer codotaka-eval heat maps).
- perf: `perf record -e cpu-clock:u` (no -g).
