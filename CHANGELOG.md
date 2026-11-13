# Changelog

## Unreleased - fixes from the 2026-11-13 code review

- **Dynamic mode froze in every engine integration**: Unity, Unreal and the Godot rect node
  called `SetTargetFps` every frame, which resets the controller's counters, so it could never
  reach the 20 / 180 frames needed to step. They now call it only when the value changes.
- **Temporal**: history is reprojected with the previous frame's UNJITTERED view-projection
  (a jittered one resampled the history at a new sub-texel offset every frame and blurred it);
  the previous-frame sample is clamped inside the image region. Contract updated in
  `maba_temporal.frag.glsl`, `.hlsl` and `.h`.
- **Unity**: render region is now set with `pixelRect` (it was `scale * 0.77`, not `scale`);
  the upscale draws to the screen instead of back into the camera's own target; works under
  URP (`endCameraRendering`); reversed-Z depth converted; depth copied per region; shaders
  moved to `Resources` so builds include them; gather-free fallback shader for ES 3.0;
  `FrameTimingManager` call fixed; URP is now optional; `ResetHistory()` for camera cuts.
- **Unreal**: the pass now binds its render target and honours `OverrideOutput`; texel size
  from the texture extent; UVs from `SV_Position`; Dynamic uses the quality shader on quality
  rungs; view extension registered after engine init; `r.Maba.Enable 0` restores 100%; ticker
  removed on shutdown; renderer private include paths; 5.3-5.5 API guards.
- **Godot**: `.shader` renamed `.gdshader`; no `return` in `fragment()`; removed constants
  that shadowed global classes; vertex format / multisample / pipeline-create arguments fixed;
  separate pipelines per framebuffer format; `draw_list_begin` works on 4.3 and 4.4;
  validity-checked frees; microsecond frame timing.
- **Test app**: the off-screen target had no depth buffer, so the *Native* benchmark ran
  without depth testing - **the "vs native" numbers in the README need re-measuring**;
  render targets freed on resize; GL objects re-created after context loss; controller only
  touched on the GL thread.
- **Test scene redesign**: a plasma reactor orb inside a geodesic cage (120 beams, 42 glowing
  joints), orbiting crystal shards and an energy beam from a finned pedestal; a blade halo;
  detailed lamp pillars (stepped plinth, faceted shaft with light strips, seams and bevels,
  collars, capital, floating lamp crystal that lights the floor); polished grid floor,
  starfield, orbit-and-dolly camera. Physically based lighting (GGX, UE mobile env BRDF, soft
  analytic shadow, emissive area lights, AO, height fog, ACES). Start-up benchmark now runs one slice per frame (no multi-second freeze) and the
  Dynamic probe times the real frame off-screen instead of drawing four extra ones (no
  periodic hitch, and no vsync wait inside the measurement).
- **Second review pass**: the test app now pauses its GL thread in the background and removes
  its thermal listener; fps / frame timing restart after resume; a frame-granular GPU timer
  (Mali r49 returns begin == end) is reported as unavailable instead of a fake 16.8 ms;
  `MABA_VULKAN` / `MABA_HIGHP` are tested by value like the other switches (`#define
  MABA_VULKAN 0` used to enable the Vulkan path); Unity restores `depthTextureMode`; Unreal's
  pass-through copy uses `FViewInfo`; Godot samples the view-0 colour layer; JNI null checks;
  Java temporal parameter validation; C header clean under `-Weverything`.
- **Third review pass (line by line)**: Unity temporal never ran under URP
  (`Shader.GetGlobalTexture` cannot see URP's command-buffer depth texture; the depth copy now
  samples `_CameraDepthTexture` directly) and URP's depth setting is restored; Unreal's quality
  build is a shader permutation instead of a second class that re-bound the parameter struct;
  Godot reinstalls its effect when the node re-enters the tree, times frames independently of
  `Engine.time_scale`, binds a late-assigned SubViewport and checks the version by hex; the FSR1
  licence notice lists every derived file and now ships inside the Unity package and Unreal
  plugin; `compile_shaders.ps1` no longer aborts on the first compiler message, drops a
  duplicate variant and also checks the Godot, HLSL, UE and Unity shaders (31 total); test app
  deletes shader objects, keeps the benchmark's temporal history across a tap, closes the dump
  file on errors, stops polling a frame-granular timer, and guards `atan(0, 0)`; `MabaHalton`
  rejects base < 2; reference tool checks its allocations.
- `maba_upscaler.h` / `maba_temporal.h` functions are `static inline` (no unused-function
  warnings); `MABA_NO_GATHER` switch in the HLSL core.

## 2.0.0 - 2026-11-12

- **MABA-Upscaler 2 (Temporal)**: optional temporal resolve tier. Camera reprojection with
  depth, disocclusion rejection, YCoCg variance clipping, motion-faded history blend.
  History and depth ping-pong at render resolution. ES 3.0-capable. New `maba_temporal.frag.glsl`
  and `maba_temporal.h` (Halton 2/3 jitter, 16 phases, reset rules).
- **Continuous resolution**: the Dynamic ladder is now 29 rungs in 1% steps (0.50-0.77);
  the five presets remain as anchors. Less visible popping when quality shifts.
- **GPU timing**: `MabaBeginFrameGpu()` for timer-query time; `MabaSetTargetFps()` for thermal
  or battery budget changes; `MabaSeedRung()` for startup calibration.
- **Border correctness**: the 2x2 position is clamped at both ends and the 12-tap kernel
  guards all four edges; `MABA_HIGHP` option for full-precision accumulation (free on Mali-G52,
  recommended for the quality build).
- **Engine integrations**: Unity package (spatial + temporal + dynamic), Unreal Engine 5
  plugin (spatial + dynamic, compiles the real C controller), Godot 4 addon (spatial + dynamic).
  Engine-neutral HLSL cores in `src/`, synced by `test/sync_hlsl.ps1`.
- **Test app**: real 3D "MABA Core" scene (striped torus knot, thin emissive spokes, grid
  floor, orbiting camera) replaces the 2D pattern; settings panel (sharpness, target fps);
  thermal-aware target; GPU timer queries with a glFinish-probe fallback for frame-granular
  drivers; the real C controller runs on-device via JNI; reference-pattern PPM dump for
  GPU-vs-CPU verification.
- **Verification**: host C self-tests and temporal property tests; 20,000-frame controller
  parity across C / Java / C#; CPU shader reference with golden images; Mali-G52 output
  diffed against the reference (max 2-3/255); glslc compile-check of 17 variants; fxc SM5
  compile-check of the HLSL cores.

## 1.4.0 - 2026-11-12

First public release.

- Quality build: low-contrast pixels now cost the same 2 texture reads as the fast build; only
  pixels on visible edges pay for the 12-tap kernel.
- Relicensed under Apache 2.0. Repository layout, logo, notices.

## 1.3

- Quality modes: Dynamic (default), Ultra Quality, Quality, Balanced, Performance.
- `maba_upscaler.h`: mode presets and the Dynamic controller.
- The shader can read from a region of a larger texture, so changing resolution never
  reallocates the render target.

## 1.2

- Quality build made adaptive: the 12-tap edge kernel fades in by local contrast.

## 1.1

- New default path: edge-directed reconstruction from the 2x2 block, about 1 ms per frame over
  bilinear on a Galaxy A05.

## 1.0

- Single-pass upscaler with a 12-tap luma kernel derived from FSR 1.0 EASU.
