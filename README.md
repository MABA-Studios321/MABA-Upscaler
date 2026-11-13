<p align="center">
  <img src="assets/logo.svg" alt="MABA Upscaler" width="560">
</p>

<p align="center">
  <a href="LICENSE"><img alt="Licence: Apache 2.0" src="https://img.shields.io/badge/licence-Apache%202.0-blue"></a>
  <img alt="Version 2.0.0" src="https://img.shields.io/badge/version-2.0.0-F5A524">
  <img alt="OpenGL ES 3.0+ and Vulkan" src="https://img.shields.io/badge/OpenGL%20ES%203.0%2B%20%7C%20Vulkan-GLSL-green">
</p>

# MABA Upscaler

A single-pass spatial upscaler built for low-end mobile GPUs, plus an optional temporal tier:
**MABA-Upscaler 2 (Temporal)**. Render your game at a lower resolution, and MABA upscales and
sharpens it to the screen in one cheap fragment-shader pass. The temporal tier accumulates a
jittered frame sequence into a stable, effectively anti-aliased image before the upscale.

Desktop-oriented upscalers such as FSR 1.0 can cost more than they save on entry-level phones.
On a Samsung Galaxy A05, FSR 1.0 took about 18 ms per frame more than a plain bilinear upscale,
which is more than a whole 60 fps frame. MABA's fast shader takes about 1 ms more; the temporal
resolve about 3 ms more.

- One fragment-shader pass. No compute shader, no intermediate full-res render target.
- Half-precision maths in the fast build; 2 texture reads per pixel.
- Quality modes: **Dynamic** (default), Ultra Quality, Quality, Balanced, Performance.
- Dynamic mode moves render scale in **1% steps** (0.50-0.77) to hold a target frame rate,
  without ever reallocating a render target.
- Sharpening that cannot ring or overshoot, and that fades out in near-black areas.
- **MABA-Upscaler 2 (Temporal)**: camera reprojection, depth disocclusion rejection, YCoCg
  variance clipping. Optional, ES 3.0-capable, history at render resolution to save bandwidth.
- OpenGL ES 3.0, OpenGL ES 3.1+ and Vulkan from one GLSL source file; HLSL cores for engines.
- Engine integrations: **Unity**, **Unreal Engine 5**, **Godot 4** (see `integrations/`).

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
integrations/
  unity/                    Unity package (URP / built-in), spatial + temporal
  unreal/                   UE5 plugin, spatial + dynamic (temporal planned)
  godot/                    Godot 4.3 / 4.4 addon, spatial + dynamic
test/
  android/                  3D benchmark app; builds without Gradle; JNI runs the real C header
  native/                   Host tests: controller, temporal math, CPU shader reference, parity
  compile_shaders.ps1       glslc compile-check of every shader (GLSL, Godot, HLSL, UE, Unity)
  sync_hlsl.ps1             Syncs HLSL cores / C header into the engine plugins
```

## Modes and rungs

The Dynamic ladder has 29 rungs: 0-9 are scale 0.50-0.59 with the fast shader, rung 10 is 0.59
with the quality shader, rungs 11-28 are 0.60-0.77 with the quality shader. The presets are
anchors: Performance = 0, Balanced = 10, Quality = 18, Ultra Quality = 28.

Dynamic watches a smoothed frame time. If it stays more than 2% over the target for 20 frames,
it steps down one rung. After 180 good frames it tries one rung up; if that attempt fails, the
wait before the next one doubles (up to 3600 frames), and relaxes again once a step up has held
for 300 frames. `MabaBeginFrameGpu()` accepts GPU-only timer-query time so the controller sees
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
reprojects the previous resolve with depth and the inverse view-projection (camera-only, no
motion vectors), rejects disocclusions by depth comparison, clamps history into the current
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
int texW, texH;
MabaMaxRenderSize(outW, outH, &texW, &texH);   // allocate sceneTex at this size, once

// Every frame (GPU timer time preferred over present-to-present):
MabaFrame f = MabaBeginFrameGpu(&maba, lastGpuMs, outW, outH);
// render scene into viewport (0,0,f.renderWidth,f.renderHeight), then:
float size[4], params[4];
MabaUniforms(&f, texW, texH, 0.5f, size, params);
// bind f.qualityShader ? progQuality : progFast, set uniforms, draw 3 vertices, draw UI.
```

Temporal tier: see the contract at the top of `maba_temporal.frag.glsl` and `maba_temporal.h`
(jitter sequence, matrix pair, ping-pong slots, reset rules). The Android app (run on device)
and the Unity package (not yet editor-run) contain complete integrations to copy from.

Requirements: finished LDR gamma-space input after tonemapping; image region starts at texel
(0,0); UI drawn after the upscale at output resolution.

## Engine integrations

| Engine | Location | Spatial | Dynamic | Temporal |
|---|---|---|---|---|
| Unity 2021.3+ (URP / built-in) | `integrations/unity/` | yes | yes | yes |
| Unreal Engine 5.3-5.8 | `integrations/unreal/` | yes | yes | planned |
| Godot 4.3 / 4.4 | `integrations/godot/` | yes | yes | not exposed by engine |

Each integration's README states exactly what was verified and what was not. The Unity C#
controller and the Android Java controller are parity-tested against the C header; the UE
plugin compiles the C header itself.

## Benchmark app

`test/android` renders the 3D "MABA Core" scene (a plasma reactor orb in a geodesic cage with
orbiting crystals, a blade halo, detailed lamp pillars and a polished grid floor, lit with
physically based shading), benchmarks every mode off-screen at start-up without freezing the
screen, and lets you tap through modes; long-press opens settings (sharpness, target fps).
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

- **Shader compilation** (`test/compile_shaders.ps1`, NDK glslc): 31 variants - the GLSL
  builds (ES 3.0/3.1, Vulkan, fast/quality/highp, temporal), the test-app shaders, the Godot
  RenderingDevice shaders, the HLSL cores (fast, quality, gather-free, temporal), the UE pixel
  shader in both permutations and the Unity depth-copy pass.
- **Controller**: C self-tests (step down/up, back-off, cap, pauses, targets, seeding);
  20,000-frame deterministic traces identical across C, Java (Android) and C# (Unity).
- **Temporal math**: host property tests - reset/sky/off-screen/disocclusion passthrough,
  ghosting bound (white history over black frame stays black), static convergence,
  neighborhood AABB bound, motion falloff, YCoCg roundtrip, Halton range/cycle.
- **Shader correctness on GPU**: Mali-G52 output diffed against the CPU reference, both
  builds: max channel error 2/255 (hardware bilinear weight quantization). The exception is a
  handful of pixels exactly at the corners of a 4-texel checkerboard in the quality build,
  where the edge direction cancels to zero and GPU/CPU rounding picks different sides (an
  inherent tie of the FSR1-derived kernel, not reachable by ordinary content).
- **On device**: Galaxy A05: the numbers above (original scene); with the current, heavier
  scene Dynamic holds 60 fps at about 0.59 scale.

Not yet done: Unity editor / UE / Godot editor runs (no engines on the build machine at
release time); Adreno and PowerVR devices; ES 3.0-only devices; Vulkan runtime.

## Status and limitations

- Spatial MABA adds no anti-aliasing and no temporal stability; use the temporal tier for that.
- The temporal tier is camera-only: fast-moving objects can ghost slightly; the neighborhood
  clamp bounds the error. Per-object motion vectors are a future increment.
- One device measured. Reports from other devices are very welcome.
- Engine plugins are code-complete and compiler-verified but not yet editor-run; treat them
  as a strong starting point and validate on your target engine version.

## Licence

MABA Upscaler is licensed under the [Apache License 2.0](LICENSE). The Unity package, the
Unreal plugin and the Godot addon each include the notices, so they can be copied on their own.
Copyright 2026 MABA Studios. MABA Studios is owned by Muhammad Affan Bin Adnan.

The quality build's kernel is derived from AMD FidelityFX Super Resolution 1.0, copyright
Advanced Micro Devices, Inc., under the MIT licence. The temporal tier's variance-clipping
approach is inspired by FSR 2 (independent implementation). See [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); both must be kept with any redistribution.
MABA Upscaler is not affiliated with or endorsed by AMD.