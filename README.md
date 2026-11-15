<p align="center">
  <img src="assets/logo.svg" alt="MABA Upscaler" width="560">
</p>

<p align="center">
  <a href="LICENSE"><img alt="Licence: Apache 2.0" src="https://img.shields.io/badge/licence-Apache%202.0-blue"></a>
  <img alt="Version 2.0.0" src="https://img.shields.io/badge/version-2.0.0-F5A524">
  <img alt="OpenGL ES 3.0+ and Vulkan" src="https://img.shields.io/badge/OpenGL%20ES%203.0%2B%20%7C%20Vulkan-GLSL-green">
</p>

# MABA Upscaler

A single-pass spatial upscaler that is cheap enough for low-end mobile GPUs and scales up to any
resolution and frame-rate target, plus optional temporal tiers: **MABA-Upscaler 2 (Temporal)**
and **Temporal SR**. Render your game at a lower resolution, and MABA upscales and sharpens it
to the screen in one cheap fragment-shader pass. The temporal tiers accumulate a jittered frame
sequence into a stable, effectively anti-aliased image. There are no device-class checks in the
code and the render-scale ladder is not capped by default: Dynamic mode can use the whole
0.35-1.00 range and, at 1.00, steps out of the way (no upscale pass). All measurements below
come from one low-end phone; of the engine integrations only Godot has been run (see Engine integrations).

Desktop-oriented upscalers such as FSR 1.0 can cost more than they save on entry-level phones.
On a Samsung Galaxy A05, FSR 1.0 took about 18 ms per frame more than a plain bilinear upscale,
which is more than a whole 60 fps frame. MABA's fast shader takes about 1 ms more; the temporal
resolve about 3 ms more.

- One fragment-shader pass. No compute shader, no intermediate full-res render target.
- Half-precision maths in the fast build; 2 texture reads per pixel.
- Quality modes: **Dynamic** (default), Ultra Quality, Quality, Balanced, Performance.
- Dynamic mode moves render scale in **1% steps over the whole 0.35-1.00 ladder** (native
  included) to hold a target frame rate, without ever reallocating a render target, and climbs by
  several steps at once when the measured frame time says they fit. Narrow it with a range.
- Sharpening that cannot ring or overshoot, and that fades out in near-black areas.
- **MABA-Upscaler 2 (Temporal)**: camera reprojection, depth disocclusion rejection, YCoCg
  variance clipping. Optional, ES 3.0-capable, history at render resolution to save bandwidth.
- **Temporal SR**: temporal super-resolution that accumulates at OUTPUT resolution; in a calm
  scene it scores 1.2-2.3 dB above the render-resolution tier and above a native render (Android
  test app only; see "Image quality, measured").
- OpenGL ES 3.0, OpenGL ES 3.1+ and Vulkan from one GLSL source file; HLSL cores for engines.
- Engine integrations: **Unity**, **Unreal Engine 5**, **Godot 4** (see `integrations/`).
- **MABA Frame Gen (2x), prototype**: optional frame generation that shows two frames for every
  real one without holding any real frame back (see below). It does not force VSync on. Android
  test app only so far.

## Results

Samsung Galaxy A05 (Mali-G52 MC2, OpenGL ES 3.2), output 1541x720, the original 3D test scene
(striped torus knot, thin emissive spokes, grid floor, orbiting camera). Measured
off-screen so the 60 Hz display cap does not apply; one representative run.

| Mode | Render scale | Frame time | FPS | vs native |
|---|---|---|---|---|
| Native resolution | 1.00 | 27.5 ms | 36.4 | - |
| Ultra Quality | 0.77 | 19.9 ms | 50.1 | +38% |
| Quality | 0.67 | 17.4 ms | 57.4 | +58% |
| Balanced | 0.59 | 14.8 ms | 67.6 | +86% |
| Balanced, fast shader | 0.59 | 14.0 ms | 71.4 | +96% |
| Performance | 0.50 | 11.8 ms | 84.8 | +133% |
| Plain bilinear, no MABA | 0.59 | 13.2 ms | 75.8 | +108% |
| **MABA-Upscaler 2 (Temporal)** | 0.59 | 18.2 ms | 54.8 | +51% |

On screen, Dynamic mode held 60 fps while settling around 0.62-0.64 scale; the temporal tier
held 60 fps at 0.62 with visibly cleaner edges and no shimmer.

**Read these numbers with care.** They pre-date a benchmark fix: the off-screen *Native* run
had no depth buffer, so its frame time (and every "vs native" percentage) is likely
overstated; re-measure with the current test app. The test scene is geometry plus per-pixel
lighting with a calibrated load; a real game also has CPU and shadow costs that do not shrink
with resolution, so its gain over native will be smaller. Everything here was measured on one phone, and
absolute numbers move with device temperature. MABA spatial is sharper than bilinear and
softer than native; the temporal tier adds stability and effective AA at a small cost.

## Repository layout

```
src/
  maba_upscaler.frag.glsl   The spatial upscaler (fast build and MABA_QUALITY build)
  maba_upscaler.vert.glsl   Full-screen triangle
  maba_upscaler.h           Rungs, presets and Dynamic controller (C99 / C++, header only)
  maba_temporal.frag.glsl   MABA-Upscaler 2 (Temporal) resolve pass
  maba_temporal.h           Halton jitter and resolve state (C99 / C++, header only)
  maba_upscaler.hlsl        Engine-neutral HLSL core (Unity / Unreal)
  maba_temporal.hlsl        Temporal HLSL core
  maba_temporal_sr.frag.glsl  Temporal SR: output-resolution temporal upscaler (GLES 3.0, test app only)
  maba_framegen.frag.glsl   MABA Frame Gen warp pass (GLES 3.0+, prototype)
  maba_framegen.h           Frame Gen slot policy and honest 1-second counters (C99 / C++)
integrations/
  unity/                    Unity package (URP / built-in): spatial + temporal, inspector, Tools menu
  unreal/                   UE5 plugin: spatial + temporal, Project Settings page, Blueprint API
  godot/                    Godot 4 addon: spatial + temporal, editor menu, demo, headless + render tests
test/
  android/                  3D benchmark app; builds without Gradle; JNI runs the real C header
                            (panel_fps.ps1 and gpu_slots.ps1 measure the panel / per-slot GPU time)
  native/                   Host tests: controller, temporal, frame gen, CPU shader reference, parity
  run_host_tests.ps1        Builds and runs every host test and the C / Java / C# controller parity
  compile_shaders.ps1       glslc compile-check of every shader (GLSL, Godot, HLSL, UE, Unity)
  sync_hlsl.ps1             Syncs HLSL cores, C headers, notices and READMEs into the plugins (-Check verifies)
```

## Image quality, measured

The test app measures quality objectively on the device (`--ei qsweep 1`): the scene is rendered
at each preset's scale, upscaled, and compared with a **2x-supersampled** render (centre crop, 3
scenes) by two numbers: PSNR in dB (higher is closer), and **detail kept**, the share of the
reference's fine gradient energy the image still has (blur lowers it, over-sharpening raises it
above 100%). An ordinary native render is aliased and scores only **24.82 dB / 108%**, which is the
ceiling for any path that does not anti-alias. Galaxy A05, sharpness 0.5, PSNR dB / detail kept.

Moving scene (the animated test scene):

| Render scale | Bilinear | MABA fast | MABA quality | Temporal (old) | **Temporal SR** |
|---|---|---|---|---|---|
| 0.50 | 21.35 / 91% | 21.41 / 94% | 21.21 / 101% | 20.72 / 75% | **21.53 / 99%** |
| 0.59 | 22.39 / 93% | 22.43 / 97% | 22.27 / 102% | 22.20 / 84% | **22.59 / 99%** |
| 0.67 | 23.27 / 95% | 23.29 / 99% | 23.08 / 103% | 23.12 / 87% | **23.44 / 99%** |
| 0.77 | 24.16 / 97% | 24.16 / 100% | 23.92 / 104% | 23.98 / 89% | **24.07 / 100%** |

Calm scene (scene frozen, as in a slow camera or a static shot):

| Render scale | Bilinear | MABA fast | MABA quality | Temporal (old) | **Temporal SR** |
|---|---|---|---|---|---|
| 0.50 | 21.35 / 91% | 21.41 / 94% | 21.21 / 101% | 21.50 / 79% | **23.59 / 96%** |
| 0.59 | 22.39 / 93% | 22.43 / 97% | 22.27 / 102% | 23.05 / 88% | **24.69 / 98%** |
| 0.67 | 23.27 / 95% | 23.29 / 99% | 23.08 / 103% | 24.10 / 90% | **25.52 / 99%** |
| 0.77 | 24.16 / 97% | 24.16 / 100% | 23.92 / 104% | 24.95 / 92% | **25.81 / 100%** |

What this says, plainly. The spatial upscalers (bilinear, MABA fast, MABA quality) are within 0.2
dB of each other: a spatial filter cannot recover detail the low-resolution render never
contained, and sharpening trades fidelity for crispness (the quality build scores below bilinear
on PSNR). The old Temporal tier did not fix that: it accumulated at render resolution, so it kept
only 75-90% of the detail. **Temporal SR** accumulates at output resolution: in a calm scene it
gains 1.2-2.3 dB over the old tier at every scale and passes a native render at 0.59 scale and
above; at 0.50 scale it (23.59 dB) beats the spatial upscalers at 0.67 (23.29 dB). In a moving
scene it keeps 99% of the detail (old tier 75-89%) but gains only +0.1 to +0.4 dB: moving
pixels must distrust their history, and what is left is mostly the spatial estimate.

### Temporal SR (`src/maba_temporal_sr.frag.glsl`)

An output-resolution temporal upscaler (resolve pass plus a light sharpen "present" pass), same
inputs and jitter contract as the Temporal tier plus per-pixel motion vectors. Per output pixel it
reads the jittered render texels around it once and weights them twice by their true distance: a
narrow kernel (accumulated) and a wide, bilinear-like one (the fallback). History is reprojected
with the motion vectors, clamped to the neighbourhood in YCoCg, and blended as a **weighted**
running average (the history keeps the sum of kernel weights); the shown image blends the
accumulated history with the wide estimate by that confidence, so a young or moving pixel looks
like a good spatial upscale. GLSL ES 3.0 only so far; it needs half-float render targets. It is
**not** ported to the Unity / Unreal / Godot integrations yet, and has no host test (it was
validated by the on-device measurement above).

Getting it to work needed four findings, each measured (the first versions scored *below* the old
tier, 22.43 dB calm):

- A **depth/disocclusion test that is always on destroys accumulation**: for thin geometry the
  depth seen at neighbouring jitter positions differs at every edge, so history was rejected
  exactly where super-resolution matters (calm scene 22.0 -> 25.1 dB when switched off). It now
  applies only to pixels that really move (`MABA_TSR_DEPTH_MOTION`).
- History needs **weights, not a fixed blend**. A "new frame always counts at least 10%" rule
  injected far-sample noise every frame; the weighted running average has no minimum share.
- A **wide prior** shown by confidence keeps moving pixels at spatial-upscale quality (moving
  scene 21.97 -> 22.59 dB), without ever entering the history.
- Not the cause, measured: the history clamp (no clamp gave the same 22.91 dB) and the jitter
  sign (the documented convention scores 20.59 dB with history off, every other sign 16-19 dB).

**What it costs (Mali-G52, 1541x720).** The extra passes run at output resolution: the first
version cost +18 ms over the old Temporal tier. Reading a 2x2 block of render texels instead of
3x3 and a bilinear instead of Catmull-Rom history (both measured: 0.00-0.02 dB moving, -0.27 dB
calm) brought it to **+5-7 ms** (22.2 vs 15.4 ms on the light scene; uncapped on the calibrated
scene 62.1 -> 47.9 fps). Half-precision arithmetic saved only 0.4 ms (`MABA_TSR_HIGHP 0`).
That is a real price: Temporal SR is the quality tier for scenes with slow or settled camera
motion, not a way to gain frame rate on this GPU. Render scale 0.50 costs about the same as
0.59 on this test scene (it is not pixel-bound), so its lower scale buys quality per pixel but
not frame rate here.

Developer extras for the sweep: `qsweep 1` (all four scales + native), `tfreeze 1` (calm scene),
`qtf N` (frames accumulated), `tsr 0` (old Temporal path), and `tsrr`, `tsrrw`, `tsrprior`,
`tsrwmax`, `tsrk`, `tsrtaps`, `tsrhist`, `tsrhp`, `tsrsharp` for the shader switches.

### Earlier findings (previous release)
What the first version of this measurement found and fixed (earlier numbers in the same test:
MABA quality 22.13 dB, Temporal 18.56 dB):

- **Temporal ignored its own jitter.** The current frame is rendered shifted by up to half a
  texel and was read as if centred, costing 2.7 dB before any history was used. It is now read
  back at the un-jittered position (`uMabaJitter`). The Unity package also applied the jitter
  with the opposite sign to the reference app; fixed.
- **History hurt moving content.** Camera-only reprojection loses every moving object, and
  history was only mildly distrusted for moving pixels. Per-object motion vectors recovered
  +1.9 dB, and a stronger motion distrust (`MABA_TEMPORAL_MOTION_K` 0.05 -> 4) makes history
  never worse than none on an animated scene while keeping its +0.6 dB gain on a calm one.
- **The quality build overshot.** Its edge-reconstruction gain scored 22.13 dB at 1.0 and 22.40
  dB at 0; the default gain is now 0.5 (`MABA_QUALITY_GAIN`). The 12-tap kernel does not
  measurably beat bilinear on this content (thin aliased lines); no spatial upscaler can recover
  detail the low-resolution render never contained, only temporal accumulation can, and its
  ceiling here is about +0.6 dB because the scene animates constantly (pulses, plasma).
- Costs: per-object motion vectors add about 2 ms to a Temporal frame on this phone (17.6 ->
  19.5 ms); a Catmull-Rom history resample (`MABA_TEMPORAL_SHARP`) added +0.1 dB for 0.5 ms and
  is off by default.

## Modes and rungs

The Dynamic ladder runs from rung -15 to rung 51 in 1% render-scale steps: rungs -15..9 are
scale 0.35-0.59 with the fast shader, rung 10 is 0.59 with the quality shader, and rungs 11-51
are 0.60-1.00 with the quality shader. **Rung 51 is native**: the frame is rendered at output size
and the upscale pass is skipped (`MabaFrame.isNative`). The presets are anchors: Performance = 0,
Balanced = 10, Quality = 18, Ultra Quality = 28.

**The range is not capped for a hardware class.** Dynamic mode uses the whole ladder by default,
so a weak GPU can drop to 0.35 and a strong one can climb to native, where MABA costs nothing.
(Earlier builds stopped at 0.77, so a GPU with spare time above that could never use it.)
`MabaSetScaleRange(&maba, min, max)` narrows the range when a game wants a quality floor or a
ceiling (Unity `minScale` / `maxScale`, Unreal `r.Maba.MinScale` / `r.Maba.MaxScale`, Godot
`min_scale` / `max_scale`); the fixed presets ignore it. `MabaMaxRenderSizeFor()` gives the
render-target size that range needs.

Dynamic watches a smoothed frame time. If it stays more than 2% over the target for 20 frames,
it steps down one rung. After 180 good frames it steps up, **by as many rungs as the measured
headroom predicts will fit**: the frame time at a higher rung is estimated as if the whole frame
scaled with the pixel count (`avg * (p / p0)^2`, an upper bound for a frame that is only partly
pixel-bound), and the highest rung predicted to use at most 90% of the budget is taken, up to 16
rungs at once. A step up that fails returns to the rung it started from in one step, and the wait
before the next one doubles (up to 3600 frames); it relaxes again once a step up has held for 300
frames. On the test phone with a 30 fps target this climbed from 0.59 to 0.99 (the old ladder
stopped at 0.77). `MabaBeginFrameGpu()` accepts GPU-only timer-query time so the controller sees
headroom even under vsync; `MabaSetTargetFps()` lets a thermal handler lower the budget.

## How the shaders work

**Fast build.** For every output pixel it looks at the 2x2 block of input texels around it.

1. *Edge-directed interpolation.* The block is split into two triangles along whichever
   diagonal has less contrast, so a diagonal edge is followed instead of blurred across.
2. *Weight sharpening.* The interpolation weights are steepened, which narrows edges. The
   result always stays between the four source texels, so it cannot ring.
3. *Dark fade.* Sharpening fades out in near-black areas.

**Quality build** (`MABA_QUALITY 1`). Low-contrast pixels take the fast path at the same cost.
Pixels on visible edges fade in a 12-tap edge-adaptive kernel on luma, derived from FSR 1.0's
EASU, which follows the edge direction and removes most stair-stepping. `MABA_HIGHP 1` selects
full-precision accumulation (recommended; free on Mali-G52).

**MABA-Upscaler 2 (Temporal)** (`maba_temporal.frag.glsl`). One pass at render resolution:
reads the current frame back at its un-jittered position, reprojects the previous resolve with
either the camera matrices or (`MABA_TEMPORAL_VELOCITY`) per-pixel motion vectors, rejects
disocclusions by depth comparison, clamps history into the current
3x3 neighborhood's YCoCg mean +/- gamma*sigma box intersected with its AABB, and blends with a
motion-faded weight. History is reprojected with the previous frame's unjittered matrix. Its
output feeds the spatial upscale. History and depth ping-pong at render resolution. Reset on
camera cuts, scale changes and the first frame.

## Quick start (GLES / Vulkan)

Neither shader has a `#version` line. Prepend one of these headers to **both** shaders, and
build the fragment shader twice: once as is (fast) and once with `#define MABA_QUALITY 1\n`.

| Target | Header |
|---|---|
| OpenGL ES 3.1+ | `#version 310 es\n#define MABA_GATHER 1\n` |
| OpenGL ES 3.0 | `#version 300 es\n#define MABA_GATHER 0\n` (fast build only; use it for every rung) |
| Vulkan | `#version 450\n#define MABA_VULKAN 1\n#define MABA_GATHER 1\n` |

Spatial shader inputs:

| Name | Type | Value |
|---|---|---|
| `uMabaInput` | sampler2D | The low-resolution frame. LINEAR filter, CLAMP_TO_EDGE, no mipmaps. |
| `uMabaInputSize` | vec4 | `xy` = size in texels of the image region, `zw` = 1 / texture size. |
| `uMabaParams` | vec4 | `x` = sharpness, 0 to 1. Start at 0.5. `yzw` unused. |

```c
#include "maba_upscaler.h"

MabaUpscaler maba;
MabaInit(&maba, MABA_MODE_DYNAMIC, 60.0f);
// optional: MabaSetScaleRange(&maba, 0.50f, 0.85f);   // default: the whole 0.35 .. 1.00 ladder
int texW, texH;
MabaMaxRenderSizeFor(&maba, outW, outH, &texW, &texH);   // allocate sceneTex at this size, once

// Every frame (GPU timer time preferred over present-to-present):
MabaFrame f = MabaBeginFrameGpu(&maba, lastGpuMs, outW, outH);
// render scene into viewport (0,0,f.renderWidth,f.renderHeight); if f.isNative, present it
// directly (no upscale pass). Otherwise:
float size[4], params[4];
MabaUniforms(&f, texW, texH, 0.5f, size, params);
// bind f.qualityShader ? progQuality : progFast, set uniforms, draw 3 vertices, draw UI.
```

Temporal tier: see the contract at the top of `maba_temporal.frag.glsl` and `maba_temporal.h`
(jitter sequence, matrix pair, ping-pong slots, reset rules). The Android app (run on device)
and the Unity package (not yet editor-run) contain complete integrations to copy from.

Requirements: finished LDR gamma-space input after tonemapping; image region starts at texel
(0,0); UI drawn after the upscale at output resolution.

## MABA Frame Gen (2x), prototype

Optional, off by default. After every real frame the game renders, MABA builds one extra frame
and shows it, so a 60 Hz panel shows 60 frames from 30 real ones. It is **extrapolation**: the
extra frame is predicted forward by half a real-frame interval from the newest real frame alone
(its colour, depth and per-pixel motion vectors, camera and objects), so no real frame is ever
held back waiting for a later one. That is the difference to interpolating frame generators
(DLSS / FSR frame generation), which hold the newest real frame to show an in-between one.

How a generated frame is made (`maba_framegen.frag.glsl`, one pass at render resolution, then
the normal MABA upscale): smooth areas are pulled straight from where the surface was; around
moving edges the shader looks along the fast motion for surfaces that really land on the pixel
and the nearest one wins (no ghost copies); newly uncovered areas take background, from the
previous real frame where it saw the same surface, otherwise by extending the nearest
background. `maba_framegen.h` is the real/generated alternation and the counters.

**Measured on the Galaxy A05 (Mali-G52), one device, one scene; read with care:**

- **Honest counters, and VSync is your choice.** The app's overlay counts frames when they are
  handed to the display, in one-second windows, and publishes the numbers once per second: with
  Frame Gen on and VSync on it shows `REAL 30 + GENERATED 30 = SHOWN 60 fps`; with VSync off it
  shows `REAL 37 + GENERATED 37 = OUTPUT 75 fps (panel shows 60)`. Nothing is multiplied or
  smoothed. **Frame Gen does not force VSync on:** the swap interval follows the VSync setting
  alone (earlier builds paced Frame Gen to the panel whatever the setting, which held the real
  frame rate to half the refresh rate). Uncapped, a fixed-refresh panel still shows at most one
  frame per refresh, so the compositor discards the frames it cannot show (Balanced: the app
  counted 74.8 fps while the panel displayed 60.1). The real frames, which carry the input, run
  at their own rate instead of being pinned to half the refresh. The panel record below cannot
  say WHICH frames were kept: when real or generated frames are discarded, the steps between the
  frames you see are not strictly real / generated / real / generated, so VSync on is the choice
  for a strict alternation and VSync off the choice for the highest real frame rate. One
  measured trap: asking for swap interval 0 once, on the first frame, was not always honoured
  (11 of 34 launches stayed locked to the panel at 30 real + 30 generated although the call
  succeeded), so the app repeats the request on a back-off schedule (0 of 16 locked since; see
  the changelog); a game that sets an uncapped swap interval should verify the rate it really
  gets. On a panel faster than 60 Hz (not tested, no such device here) the same setting would
  show as more frames on the glass. Without Frame Gen and with VSync off, a rate above the
  panel's is shown as "N fps rendered, panel shows 60".
- **What the panel really shows.** The phone's display has one mode, **60 Hz**, so no frame
  rate above 60 can ever be seen, whatever the technology; counters of presented frames with
  VSync off (the "+15-49%" figures this README used to quote) count frames the GPU finished, not
  frames on the glass. Ground truth comes from `test/android/panel_fps.ps1`, which reads
  SurfaceFlinger's record of the frames it actually displayed (VSync on, the real start-up path,
  scene load calibrated by the start-up benchmark; one device, one scene; measured before the
  forced VSync was removed, i.e. this is what Frame Gen did at that time):

  | Mode | Without Frame Gen | With Frame Gen |
  |---|---|---|
  | Native | 32.4 fps, 15% of gaps even | **49.0 fps (+51%)**, 77% even |
  | Ultra 0.77 | 43.4 fps, 62% even | **59.3 fps (+37%)**, 99% even |
  | Quality 0.67 | 51.2 fps, 84% even | **59.8 fps (+17%)**, 99% even |
  | Balanced 0.59 | 59.3 fps, 99% even | 60.1 fps, 100% even |
  | Performance 0.50 | 60.1 fps, 100% even | 60.1 fps, 100% even |

  "Even" is the share of gaps between displayed frames that are exactly one refresh (16.7 ms);
  the rest are frames held for two refreshes, which is the judder you see. Frame Gen turns a
  hitching 30-50 fps into an evenly paced 60 wherever the scene is too heavy to reach 60 alone,
  and changes nothing where it already does. Native resolution is supported since this build:
  real frames render at full size and the warp writes the window directly.

  The same measurement on the current build with VSync **off** (the test app's default), Frame
  Gen off and on. "Real" is what the game itself rendered per second, "output" is real plus
  generated; the panel cannot show more than 60 whatever the output is (one device, one scene,
  one run each):

  | Mode | Without Frame Gen: real / on the panel (even) | With Frame Gen: real, output / on the panel (even) |
  |---|---|---|
  | Native | 33.4 / 34.2 fps (24%) | 24.9, 49.7 / **50.7 fps (+48%)** (82%) |
  | Ultra 0.77 | 44.7 / 45.5 fps (68%) | 29.8, 59.6 / **60.1 fps (+32%)** (100%) |
  | Quality 0.67 | 53.5 / 54.7 fps (90%) | 33.9, 68.8 / 60.1 fps (+10%) (100%) |
  | Balanced 0.59 | 62.2 / 60.1 fps (100%) | 37.4, 74.8 / 60.1 fps (100%) |
  | Performance 0.50 | 67.4 / 60.1 fps (100%) | 39.4, 78.8 / 60.1 fps (100%) |

  Against the forced-VSync build the same 60 fps reaches the glass, but the real frame rate is
  no longer pinned to half the refresh: where Frame Gen filled the panel it used to be exactly
  30 (Quality 29.9, Balanced and Performance 30.0), and is now 33.9, 37.4 and 39.4 fps (+13%,
  +25%, +31%) - more input updates per second and fresher frames for the same picture rate.
  Where the GPU is the limit there is nothing to gain: Native (24.5 -> 24.9) and Ultra (29.7 ->
  29.8), where a pair costs `R + ~11 ms` and already fills about 33 ms. The gaps are time-based:
  they cannot say which frames the compositor kept (see above).
- **Where a pair's GPU time goes, measured (it applies to any panel).** Visible 2x needs a
  generated frame that costs almost nothing, and it does not. Per-slot GPU time comes from the
  platform's own frame-completion times (`test/android/gpu_slots.ps1`: Frame Gen uncapped, GPU
  saturated, Native resolution, 1.1 megapixels): a presented plain copy of the last real frame
  costs **0.8 ms**; the generated frame with the warp costs **7.7 ms** - copy 0.8, smooth path
  about 3.2, the 8-tap probe about 1.8, edge search about 2.5; the real frame with motion
  vectors costs about 3 ms more than a normal one. So a pair costs `R + ~11 ms` for a real
  frame of cost `R`, and Frame Gen's gain in GPU terms is `2R / (R + 11)`: 1.5x when `R` is a
  33 ms frame, 1.7x at 60 ms, and only very heavy frames approach 2x. The warp is bound by
  texture fetches (about 0.4 ms per fetch per megapixel on this GPU), so it scales with the
  pixels warped and the fetches per pixel; at upscaled presets it runs at render resolution and
  costs proportionally less. The earlier explanation of "a fixed 5-6 ms per presented frame" is
  **withdrawn**: it came from frame-interval measurements, which for frames shorter than a
  refresh reflect buffer recycling, not GPU time. What Frame Gen does buy is headroom: at the
  same shown frame rate the scene gets about twice the time, which Dynamic spends on a higher
  render scale. Measured (Dynamic, 60 fps target, VSync off, 2026-11-14): without Frame Gen it
  settles at 0.59 render scale (65 fps rendered); with Frame Gen at 0.72-0.73 (real 32.5 +
  generated 32.5 = 65 fps output), about 1.5x the pixels at the same output rate. On a panel
  faster than 60 Hz (not tested, no such device here) the same headroom would show as frame
  rate.
- **The gain depends on how heavy the real frame is, and on nothing else.** Measured
  (2026-11-14, VSync off): the same scene with 4x the calibrated lighting load (`--ef loadmul 4`)
  gives Native 21.7 -> 37.4 fps output (**1.72x**, the pair costs the real frame plus about
  7.5 ms) and Quality 44.1 -> 63.7 (1.44x), against 1.5x and 1.29x on the lighter default
  scene. A pair costs `R + G` (G = generated slot plus the motion-vector overhead), so the
  gain is `2R / (R + G)`: about 1.8x once the real frame is 60-70 ms. Rendering at 1.5x and 2x
  the output size (`outw` / `outh`) works and the gain stays in the same band (Native 42.5 ->
  59.0 at 720 lines, 20.5 -> 26.2 at 1080, 11.7 -> 14.7 at 1440, light scene): the warp costs
  scale with the pixels exactly like the scene does, so resolution alone does not change the
  ratio.
- **How the cost was cut, and what was tried.** The separate pre-pass that found moving
  regions was removed (the warp probes its own neighbourhood): 3-4 ms less per pair, identical
  image quality. Reading the centre velocity once instead of twice: -0.5 ms on the generated
  frame at Native, bit-exact. Measured and **not** adopted: a 4-tap probe
  (`MABA_FG_PROBE_TAPS 4`) takes the generated slot from 8.3 to 5.3 ms with the same quality
  on this scene (22.3 / 17.3 dB), but the host test shows a 10-texel object moving diagonally
  then loses 4-25 leading-edge pixels that 8 taps keep, so it stays an opt-in speed/robustness
  trade and the default is 8; no probe at all loses 1.4 dB at fast motion. A shorter edge search
  (-0.4 ms) and skipping the refining read where motion is smooth (-0.2 ms) are not worth the
  risk. Rejected earlier: a sharper Catmull-Rom resample (worse, it rings), other search
  thresholds (no difference), a cheaper upscaler for generated frames (no consistent gain).
  **Built, measured and removed (2026-11-14): a hybrid mesh warp.** A coarse vertex grid
  (cells of 8 reference texels) moves the smooth areas for about the cost of a copy, and only
  the cells where motion changes fall back to the per-pixel shader (stencil marks, depth
  rejects the covered pixels). With every cell smooth the pair cost fell from 39.4 to about
  32 ms, i.e. the mesh itself is nearly free. On this scene it is not: the cage beams, blades
  and glints put most cells over the motion threshold, so at the default threshold the pair
  stayed at 39.4 ms (no gain) and at a loose threshold (3 texels) it reached only 37.8 ms
  (-4%), with quality unmeasured because the fused stencil/depth/colour tile pass also hung the
  GPU inside the quality check on this driver. Not shipped. A game with mostly smooth motion
  would gain more; this one cannot show it.
  Objects of about 6 texels or less fit between the probe taps and are not found.
- **Resolution independence.** The probe radius is measured in texels, so it grows with the
  render height (`k = height / 480`, at least 1; `MABA_FG_REF_HEIGHT`, or `uMabaFgParams.w` to
  override): the same physical motion is three times as many texels at 1440p as at 480p. The
  host test (`test/native/test_framegen.c`, built for 1x, 2x and 3x the reference height, same
  scene) passes every object scene at every size with the radius scaled; with it fixed at the
  reference values, fast movers lose 35 pixels at 2x and 714 at 3x. The edge threshold and the
  validity tolerance compare motion differences, and are left fixed (scaling them was measured
  neutral to slightly worse on the device, 22.5 -> 22.1 dB for the tolerance). On this phone at
  Native (720 lines, k = 1.5) the change is quality-neutral (22.5 -> 22.4 dB; 15.6 dB at 6x
  motion either way), so the phone cannot show a gain: the benefit is for higher render
  resolutions and is verified on the host only.
- **Image quality** (measured on the device against a true render of the same instant, 0.59
  scale): in this scene's gentle motion the generated frame is 25.4 dB, versus 22.5 dB for just
  repeating the last frame; with everything moving 6x faster 22.2 dB versus 15.4 dB. It helps
  most when motion is large, and is a small gain when motion is small.
- **Latency.** Not measured with a camera. By construction real frames are shown as soon as they
  are ready and the generated frame adds no waiting, so input latency is that of the real
  30 fps, plus the cost of the generation work.

**Known limits.** Needs per-pixel motion vectors from the game (the test app writes them;
Unity and Unreal produce them, but the engine integrations do not wire this up yet). No guard
band yet, so a fast camera turn smears the screen edge. Thin fast details (light strips, blades)
and anything transparent or particle-like are weaker than DLSS / FSR frame generation. The first
frame after a camera cut is real. Needs half-float render targets. Tested on one device.

## Engine integrations

> **All three engine plugins are PRE-ALPHA.** Their APIs and defaults can still change, they have had
> little real-world testing, and they are not ready for a production game. The core (the C / GLSL / HLSL
> upscaler and the Android test app) is a separate, more mature layer.

| Engine | Location | Spatial | Dynamic (whole ladder + range) | Temporal | Control surface | Verified |
|---|---|---|---|---|---|---|
| Unity 2021.3+ (URP / built-in) | `integrations/unity/` | yes | yes (`minScale` / `maxScale`) | yes | custom inspector, Tools menu, C# API | compiles against stub Unity types; **never run in Unity** |
| Unreal Engine 5.6 / 5.8 | `integrations/unreal/` | yes | yes (`r.Maba.MinScale` / `r.Maba.MaxScale`) | yes (SM5, opt-in) | Project Settings page, `r.Maba.*`, Blueprint nodes, C++ API | **builds on UE 5.6 and 5.8** (UBT + UHT); never run in a game |
| Godot 4 (Forward+ / Mobile, Vulkan) | `integrations/godot/` | yes | yes (`min_scale` / `max_scale`) | yes (depth + matrices) | inspector warnings, Project > Tools menu, demo, GDScript API | **runs on Godot 4.7** (self-test, render test, demo, editor load); 4.3 / 4.4 untested |

At scale 1.00 the integrations step out of the way: Unity renders the camera straight to the
screen (no scene texture is even allocated until a frame needs one), Godot skips the effect, and
Unreal (5.5+) does not subscribe the pass. Each integration's README states exactly what was
verified and what was not. The Unity C# controller and the Android Java controller are
parity-tested against the C header; the UE plugin compiles the C header itself; the Godot
controller and jitter sequence are tested headless on Godot 4.7 (`test/run_godot_tests.ps1`).
`test/sync_hlsl.ps1 -Check` fails if a plugin's copy of a shared file has drifted from `src/`.

## Benchmark app

`test/android` renders the 3D "MABA Core" scene (a plasma reactor orb in a geodesic cage with
orbiting crystals, a blade halo, detailed lamp pillars and a polished grid floor, lit with
physically based shading), benchmarks every mode off-screen at start-up without freezing the
screen, and lets you tap through modes; long-press opens settings (sharpness, Dynamic target from
30 to 240 fps, VSync, the Dynamic render-scale range, a thermal-limit switch). **VSync is off by
default (uncapped)**: frames are presented as soon as they are ready, so the frame rate is not
held at the panel's 60 Hz (the panel itself still only displays 60 per second, and the overlay
says so). VSync is a setting the user owns, with or without Frame Gen. The thermal limit (on by
default, switchable) caps the Dynamic target at 30 fps only when the platform reports a SEVERE
thermal status, and says so in the log. The start-up benchmark measures each mode **on screen with
VSync off**, timing real frame-to-frame intervals: on this class of driver, off-screen timing is
not trustworthy (glFinish adds ~3 ms of fixed latency to every timed frame, and frames rendered
back to back can be overlapped or partly skipped, which once made Native look 47% faster than
it is). The same latency is measured once and removed from the live Dynamic probe. The benchmark runs
every mode once on screen (no per-step calibration frames, which used to cost a 50-75 ms hitch
each). The two objective quality checks (image quality against a true render) render reference
frames and read pixels back, which measured **3.4 s of low frame rate with 16 frames over 45 ms
(worst 142 ms)**, so they no longer run at start-up: start-up now ends after the benchmark with
a single 0.2 s hitch (the one-off probe calibration), and the checks run on demand from the
settings panel ("Run image-quality check") or at start-up with `--ei qcstart 1`. The app logs
any frame over 45 ms as `HITCH` with what it was doing.
Frame Gen follows the VSync setting (see above): with VSync on its SHOWN number is exact; with it
off the overlay reports REAL, GENERATED and OUTPUT and says what the panel can show.
`test/android/panel_fps.ps1` measures what the panel really displays for every mode with Frame
Gen off and on, with `-Vsync 0|1`, from SurfaceFlinger's record of displayed frames (frames per
second and how evenly they are spaced), independent of the app's own counters.
Developer extras (intent extras: `--ei name <int>` or `--es name <text>` on `adb shell am start`):
ints `outw` / `outh` (render at a larger output size than the screen, e.g. 2312 x 1080, to
measure how every pass scales), `mode`, `vsync`, `vsyncreassert 0` (ask for the swap interval once only, to reproduce the
locked launches described above), `fg`, `target` (Dynamic target fps), `qcfast` (skip the
start-up benchmark), `fgdbg 1|2` (generated frames as plain copies / real frames only, for cost
breakdowns), `fgmask` (which Frame Gen constants scale with the render height, bit mask),
`fgprobe` (probe taps), `qfgrung` (the render rung the Frame Gen quality check runs at); strings
`smin` / `smax` (Dynamic range as render-scale fractions, e.g. `--es smin 0.5`), `sharp`, `fgk`
(force the Frame Gen resolution scale); and the Temporal SR switches listed above.

**Upscaler quality, measured against a native-resolution render** (0.59 render scale, centre
crop, PSNR; higher is closer): bilinear 21.9 dB, MABA fast 22.1 dB and MABA quality 22.1 dB at
sharpness 0, falling to 22.0 dB at 0.5 and 21.8 dB at 1.0. MABA is a little more faithful than
bilinear at low sharpness and trades fidelity for crispness as sharpness rises; no spatial
upscaler can recover detail the low-resolution render never contained (the thin cage beams), only
the temporal tier can. Sharpness 0.5 is the default.
Dynamic mode runs the **real C controller through JNI** and uses GPU timer queries where the
driver supports them, with a periodic `glFinish` probe fallback for drivers whose timestamp
queries are frame-granular (some Mali). The thermal API lowers the target to 30 fps when the
device throttles.

```
powershell -ExecutionPolicy Bypass -File test\android\build.ps1 -Install
```

Needs the Android SDK, an NDK, a JDK 11+, and the Android debug keystore. Results go to logcat
under the tag `MABA`. A `dump` intent renders reference patterns to a PPM so GPU output can be
diffed against the CPU reference on the host.

## Verification

What was actually run, and where:

- **All host tests in one command** (`test/run_host_tests.ps1`, needs gcc; Java and C# runners
  are used when a JDK / dotnet is installed): the C tests below, Frame Gen at three render
  heights, and the controller parity trace. It prints `ALL HOST TESTS PASSED`.
- **Shader compilation** (`test/compile_shaders.ps1`, NDK glslc): 42 variants - the GLSL
  builds (ES 3.0/3.1, Vulkan, fast/quality/highp, temporal, Temporal SR), the test-app shaders,
  the Frame Gen warp and its switches, the Godot RenderingDevice shaders, the HLSL cores (fast,
  quality, gather-free, temporal), the UE pixel shader in both permutations and the Unity
  depth-copy pass.
- **Controller**: C self-tests (ladder and scale range, step down/up, headroom jumps and the
  one-step return from a failed jump, native reachable, back-off, pauses, targets, seeding);
  a 55,000-frame deterministic trace (load phases that climb, fail and recover, loading hitches,
  two mid-run range changes) identical across C, Java (Android) and C# (Unity). The GDScript
  port (Godot) runs a headless self-test of the ladder, jitter sequence and setup checks on Godot 4.7
  (`integrations/godot/test/run_godot_tests.ps1`); it is not diffed against the C trace.
- **Frame Gen**: host tests of the slot policy and one-second counters, and of the warp maths
  (a line-for-line C port of the shader), built for 1x, 2x and 3x the reference render height:
  static scene unchanged, camera pan shifted by half the motion, a moving object advances with
  the nearest surface winning, no ghost copy left behind, uncovered background is background,
  diagonal movers keep their leading edge; the result must not depend on the resolution.
  On the device: the quality measurement above.
- **Temporal math**: host property tests - reset/sky/off-screen/disocclusion passthrough,
  ghosting bound (white history over black frame stays black), static convergence,
  neighborhood AABB bound, motion falloff, YCoCg roundtrip, Halton range/cycle.
- **Shader correctness on GPU**: Mali-G52 output diffed against the CPU reference, both
  builds: max channel error 2/255 (hardware bilinear weight quantization). The exception is a
  handful of pixels exactly at the corners of a 4-texel checkerboard in the quality build,
  where the edge direction cancels to zero and GPU/CPU rounding picks different sides (an
  inherent tie of the FSR1-derived kernel, not reachable by ordinary content).
- **On device**: Galaxy A05: the numbers above (original scene). Current scene, latest run
  (2026-11-14, VSync off, scene load calibrated by each run's start-up benchmark, so compare
  only within one table): rendered rate Native 33, Ultra 0.77 45, Quality 0.67 54, Balanced 0.59
  62, Performance 0.50 67 fps (the 60 Hz panel shows at most 60 of these, see Frame Gen).
  Dynamic with a 60 fps target and VSync off settled at 0.59 (quality shader, 65 fps rendered),
  and with Frame Gen on at 0.72-0.73. An earlier run of the same app measured 35 / 46 / 55 / 64 /
  74 fps for the five presets; the difference is within what a different calibration, device
  temperature and Android battery saver (on during these runs: it lowers clocks) account for,
  but it was not isolated. A charged phone without battery saver will be faster.

Not yet done: Unity editor runs (no Unity on the build machine); running the Unreal plugin in a game;
Godot 4.3 / 4.4 and the Mobile renderer; Adreno and PowerVR devices; ES 3.0-only devices; Vulkan runtime on Android.

## Status and limitations

- Spatial MABA adds no anti-aliasing and no temporal stability; use the temporal tier for that.
- MABA Frame Gen is a prototype in the Android test app; it is not in the engine plugins yet.
- The temporal tier in the engine integrations (Unity, Unreal, Godot) reprojects with the camera matrices
  and scene depth only, so moving objects ghost or lose their history; the neighbourhood clamp bounds
  the error. The Android test app already feeds it per-object motion vectors
  (`MABA_TEMPORAL_VELOCITY`), which measured +1.9 dB on an animated scene; wiring that into the
  engine integrations is the next step. Temporal SR (output-resolution accumulation) is likewise only
  in the Android test app.
- One device measured. Reports from other devices are very welcome.
- Engine plugins: the Godot addon is run-tested on 4.7, the Unreal plugin builds on 5.6 / 5.8, the Unity
  package is compile-checked only. Treat them as a strong starting point and validate on your target
  engine version.

## Licence

MABA Upscaler is licensed under the [Apache License 2.0](LICENSE). The Unity package, the
Unreal plugin and the Godot addon each include the notices, so they can be copied on their own.
Copyright 2026 MABA Studios. MABA Studios is owned by Muhammad Affan Bin Adnan.

The quality build's kernel is derived from AMD FidelityFX Super Resolution 1.0, copyright
Advanced Micro Devices, Inc., under the MIT licence. The temporal tier's variance-clipping
approach is inspired by FSR 2 (independent implementation). See [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); both must be kept with any redistribution.
MABA Upscaler is not affiliated with or endorsed by AMD.