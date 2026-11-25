# How the project was steered

This file records the human direction behind codotaka: what the owner (codotaku) decided,
corrected and pushed for, and how the project changed as a result. The AI assistant wrote
most of the code; the owner set the direction, held the quality bar, and caught the
assistant's mistakes. Earlier phases are summarized from commit history and session
summaries; later phases are recorded in more detail.

## 1. The baseline: "cutting-edge only, just me"

The owner chose to target one modern platform instead of building a portable engine:

- **Zig master**, not the stable release, and vulkan-zig master.
- **No fallback code paths.** If the target hardware and driver support something, the
  project uses it; there is no compatibility path for older drivers or other platforms.
- **Presentation without VkSwapchainKHR:** raw dmabuf buffers with linux-drm-syncobj
  explicit sync, tranche-aware format negotiation, NVIDIA-aware.
- **The newest Vulkan model throughout:** descriptor heaps accessed through untyped
  pointers (explicitly *not* set/binding mappings), shader objects instead of pipelines,
  unified image layouts, internally synchronized queues, host image copy.
- **Client-side decorations rendered with Vulkan**, not libdecor and not server-side.
- **A serious text stack:** HarfBuzz, FreeType, fontconfig, libunibreak, and SheenBidi,
  which the owner chose over FriBidi.
- **Allocator- and std.Io-aware APIs**, with independent libraries under `lib/`.

These choices shaped everything after them: the code is small and direct because it never
branches for old hardware, and it leans on very new driver features.

## 2. Phases and the owner's role in each

| Phase | What happened | Owner's contribution |
|---|---|---|
| Foundation | Wayland window, Vulkan device, dmabuf presentation, then a refactor into `lib/` libraries | Set the baseline and the library structure |
| Rendering model | Bindless descriptor heaps, shader objects, text, keyboard | Insisted on untyped-pointer heaps and SheenBidi |
| Video player | FFmpeg Vulkan Video decode on our own VkDevice, zero-copy sampling, HDR | Direction: a media foundation; reviewed the results |
| Audio | PipeWire output, audio master clock, A/V sync | "Continue": the assistant proposed, the owner approved |
| Seeking + OSD | Translucent subsurfaces, progress bar, generation-tagged seeking | Supplied the real-world test file (Big Buck Bunny 4K 60 fps); reported that audio broke after looping, which uncovered two bugs |
| Optical flow | Frame interpolation on NVIDIA's optical-flow hardware | Asked for it ("can we add vk nv optic extension"); reported every artifact with screenshots; told the assistant to research the extension online |
| Quality | Forward splatting, an offline evaluation tool | Asked what the theoretical limits were; asked for a 10 fps test clip; pushed for the proper method instead of patches |
| Tooling | GPU-side scoring, a separate `codotaka-eval` executable | Rejected CPU-side evaluation; declared the tool part of the product |

## 3. Key interventions

These are the moments where the owner's direction changed the outcome.

### "Can we add vk nv optic extension" → "try it"
The assistant had recommended against writing a custom Vulkan Video backend, while
noting that optical flow was feasible. The owner chose the experiment. That started the
longest arc of the project.

### Reporting artifacts instead of accepting "it works"
The assistant reported optical flow as working several times when it wasn't. The owner
sent screenshots each time:
- **"it's flickering aggressively"**: vectors arrived one vsync late, so frames alternated
  between interpolated and plain. The fix was to prefetch the next frame pair.
- **Garbled vector fields:** led to the discovery that the integer alias view of the
  optical-flow output was invalid.
- **"all frames look garbled up"**: led to the discovery that sampling the hardware's
  vector format returns unscaled values, 32× too large.
- **"no all frames show those red patches"**: led to clarifying and reworking the debug
  visualization.

Without these reports, the broken versions would have been committed as "done".

### "research the extension in the internet"
The assistant had been guessing how the extension behaves. Reading the Khronos spec
confirmed the vector direction convention and showed which formats can be sampled
directly. That made the final diagnosis possible.

### Protecting the desktop
The assistant's injected test keystrokes ended up in the owner's terminal, and its
screenshots captured the owner's windows. The project now tests through environment
variables and the offline evaluation tool instead.

### "what features it have?" → "go ahead"
Asking what the optical-flow hardware supported revealed unused features: hint inputs,
global flow and finer grids. It also revealed a real bug: alternating two sessions made the
hardware's temporal hints a frame stale.

### "am curious about 1" → "build it"; then "why you was holding back this from me?"
The assistant had spent several iterations patching backward warping before proposing
forward splatting, the standard modern method. The owner chose it, and the result was
"waaaay better". The owner then asked why it hadn't been proposed first. The answer was
incrementalism: the assistant tried the cheapest approach before the known-good one. The
owner's question made "put the standard method on the table first" an explicit rule.

### "what is the theoretical limit … how much would your next fixes pay off"
This turned tuning by eye into measurement and led to the offline evaluation harness.

### "I mean come on all that gpus infra to use the cpu"
The first harness computed image error on the CPU and took minutes per run. The owner
called it out. The scoring moved to a GPU compute pass and a run dropped from 2 m 34 s to
14 s. It also set a project rule: **pixel-scale work goes on the GPU.**

### "the harness is as important as the rest of the code"
The owner set the standard that tools dogfood the stack and can ship. The evaluator became
its own executable, `codotaka-eval`, with CSV output and GPU-generated heat maps.

### Scope decisions
- **Removed the code-editor goal** from the documentation: the project is a media/UI
  foundation.
- Asked for persistent context (`NOTES.md`, `README.md`) so work can resume without
  history.

## 4. Patterns in the owner's steering

- **Ambition first, cost second.** The owner chose the cutting-edge option at each fork.
- **Trust, but verify visually.** The owner was often the only reliable test of what was
  on screen.
- **Asking "why" when quality jumped.** That exposed the assistant's tendency to patch
  before proposing the standard solution.
- **Refusing waste.** Most notably, rejecting CPU work in a GPU-first project.
- **Treating tooling as product.**
- **Short go-aheads ("continue", "try it", "go ahead", "build it")** once a plan was clear,
  leaving the execution to the assistant.

## 5. How the project evolved in one paragraph

It began as a Wayland + Vulkan presentation experiment with no swapchain. It became a set of
reusable libraries (Wayland, Vulkan core, presentation, scene graph, text, decorations,
media), then a zero-copy hardware video player with HDR. Audio came next as the master
clock for A/V sync, then seeking and a translucent on-screen display. After that came
motion-compensated frame interpolation on NVIDIA's optical-flow accelerator. It went
through four rounds of artifacts before reaching forward softmax splatting, and finally an
evaluation tool, running entirely on the GPU, that measures interpolation quality against
real frames and shows exactly where it fails.
