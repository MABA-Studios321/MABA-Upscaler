# MABA Upscaler for Godot

A single-pass spatial upscaler for low-end mobile GPUs, packaged as a Godot 4.3+ addon.
Render your 3D scene at a lower resolution and MABA upscales and sharpens it to the screen
in one cheap fragment pass. Built and maintained by **MABA Studios**.

- One fragment-shader pass, no compute, half-precision maths, 2 texture reads in the fast build.
- Dynamic mode holds a target frame rate by moving render scale in 1% steps (0.50-0.77).
- Quality modes: Dynamic, Ultra Quality (0.77), Quality (0.67), Balanced (0.59), Performance (0.50).
- Sharpening that cannot ring or overshoot, and that fades out in near-black areas.

## Supported versions

- **Godot 4.3 and 4.4**, **Vulkan** renderer only (Forward+ or Mobile).
- The Compatibility (OpenGL ES) renderer is **not** supported: compositor effects need
  `RenderingDevice`, which only exists on Vulkan.
- Single-view rendering only. XR / multiview is not handled.

## Install

1. Copy the `addons/maba_upscaler` folder into your project's `addons/` directory.
2. Project → Project Settings → Plugins → enable **MABA Upscaler**.
3. Open a 3D scene that has a `Camera3D`, add a **MabaUpscaler** node (Create Node dialog),
   and set mode / sharpness / target fps in the Inspector.
4. Play. For a faithful result set the scene's `WorldEnvironment` tonemap mode to **Linear**
   and keep camera exposure at 1 (see "Colour space" below).

A demo scene is included at `addons/maba_upscaler/demo/demo.tscn` (a spinning striped torus).

`MabaUpscalerRect` is an alternative for projects that render 3D into a `SubViewport`: it is
a full-screen `TextureRect` that sizes the SubViewport from the controller and upscales its
(already tonemapped) texture with `shaders/maba_canvas.gdshader`, with no extra engine
resample. Assign the SubViewport to its `scene_viewport` property.

## How it relates to Godot's built-in temporal upscaler

Godot ships a temporal upscaler (FSR2) driven by `viewport.scaling_3d_scale`. It is excellent
on desktop and console GPUs, but its compute passes are too heavy for entry-level Android
phones — on the project's target device a desktop-oriented spatial upscaler already cost more
than a whole 60 fps frame. **MABA is the cheap tier below that**: a single fragment pass that
costs about a millisecond, aimed at low-end mobile GPUs where the temporal tier cannot run.

This addon uses the same `scaling_3d_scale` lever, but sets `scaling_3d_mode` to **BILINEAR**
and replaces the upscale with the MABA shader. Do not enable FSR2 at the same time.

## How it works (and the one important caveat)

The controller (`maba_controller.gd`) is a line-for-line port of `src/maba_upscaler.h`: the
same 29-rung ladder, the same EMA, the same step-down / step-up / exponential back-off. Each
frame the node sets `viewport.scaling_3d_scale` from the controller and tells the compositor
effect whether to use the fast or quality shader.

The effect (`maba_compositor_effect.gd`) runs at `POST_TRANSPARENT`. Verified against the
Godot 4.3/4.4 engine source, the pipeline is:

1. At `POST_TRANSPARENT`, `get_color_texture()` is the **internal** colour buffer, at the
   scaled resolution, in **linear** space (tonemap has not run yet).
2. The effect renders the MABA upscale from that internal buffer into its own **output-sized**
   `RenderingDevice` texture.
3. It blits that result back over the internal colour buffer.
4. **After** the last compositor callback, the engine's tonemap pass runs and performs the
   final internal → output resample (a bilinear stretch in BILINEAR mode).

**Caveat:** Godot 4.3/4.4 has no post-tonemap compositor hook, so a compositor effect cannot
be the literal last pass to the screen. Step 4 means the image is resampled once more by the
engine after MABA. The edge-directed reconstruction survives this, but the extra down/up
resample costs some sharpening crispness compared with a native single-pass MABA (as in the
Unity/Unreal integrations, which upscale after post-processing). This is an engine limitation,
not a shader limitation. If a future Godot exposes a post-tonemap hook, the effect can write
straight to the output and drop step 3.

### Colour space

The core MABA maths expects a perceptual (gamma / sRGB-encoded) LDR image. Godot's internal
buffer is linear, so the shader wraps the core maths in a linear ↔ gamma-2.2 conversion
(`convert_color_space`, on by default). The engine's tonemap then converts back to sRGB. For
this round-trip to be faithful, use **tonemap mode Linear** and **exposure 1**; other tonemap
modes re-curve the image after MABA. HDR values above 1.0 are clamped. Glow / depth-of-field,
if enabled, run in the engine's tonemap pass on the MABA result.

## Timing source (honest)

Godot 4.3/4.4 does not expose GPU timer queries to GDScript. The node therefore feeds the
controller **present-to-present frame time** (the interval between frames), equivalent to
`MabaBeginFrame` in the C header — not the GPU-only `MabaBeginFrameGpu`. With vsync on, this
cannot see GPU headroom, so Dynamic mode may settle a rung lower than the GPU could hold. On
the Mali-G52 target, even native timer queries are frame-granular, so GPU-only timing would
not help there anyway. If you obtain GPU time yourself, call `submit_gpu_time(ms)`.

## Runtime API

```gdscript
var maba := $MabaUpscaler
maba.set_mode(MabaUpscaler.Mode.BALANCED)
maba.sharpness = 0.5
maba.set_target_fps(30.0)   # e.g. thermal throttling
maba.submit_gpu_time(gpu_ms) # optional, if you have a GPU timer
```

## Controller self-test

A headless self-test asserts the ladder anchors, step-down to floor, step-up to ceiling,
back-off doubling and cap, and pause ignoring:

```
godot --headless --script res://addons/maba_upscaler/test_controller.gd
```

It exits 0 on success, 1 on any failed assertion.

## Limitations (read these)

- **Spatial only.** This integration does not include the temporal tier. Godot does not expose
  sub-pixel jitter control to plugins, so jittered accumulation cannot be implemented from an
  addon. There is no temporal stability or added anti-aliasing here.
- MABA is sharper than bilinear and softer than native. The extra engine resample (above)
  softens it a little more than the native integrations.
- Vulkan only; Forward+ or Mobile; single-view. Not the Compatibility renderer, not XR.
- Use tonemap Linear + exposure 1 for a faithful colour round-trip.
- **Verified by shader compilation (NDK glslc, Vulkan 450) and a desk-checked controller port.
  Not yet run inside the Godot editor or on a device** — no Godot runtime was available on the
  build host. Reports welcome, especially on Adreno and PowerVR.

## Licence

Apache-2.0, Copyright 2026 MABA Studios. MABA Studios is owned by Muhammad Affan Bin Adnan.
The quality kernel is derived from AMD FidelityFX Super Resolution 1.0 (MIT); see
`addons/maba_upscaler/THIRD_PARTY_NOTICES.md` and the repository `NOTICE` /
`THIRD_PARTY_NOTICES.md`, which must accompany redistribution. Not affiliated with or endorsed
by AMD.