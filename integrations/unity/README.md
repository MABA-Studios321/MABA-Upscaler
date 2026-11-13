# MABA Upscaler for Unity

Single-pass spatial upscaler for low-end mobile GPUs, with the optional
**MABA-Upscaler 2 (Temporal)** resolve tier. Render the camera at a lower resolution and MABA
upscales and sharpens it to the screen in one cheap pass, before your UI.

- One fragment pass, no compute, no intermediate full-res target.
- Dynamic mode holds a target frame rate by moving render scale in 1% steps (0.50-0.77),
  without reallocating the scene render target.
- Quality modes: Dynamic, Ultra Quality (0.77), Quality (0.67), Balanced (0.59), Performance (0.50).
- Optional temporal tier: jittered accumulation with depth reprojection and YCoCg variance
  clipping. Kills shimmer, adds effective AA. Costs ~1-3 ms on low-end mobile; off by default.

## Install

Unity 2021.3+ (URP or built-in pipeline).

1. Copy `com.maba.upscaler` into your project's `Packages/` folder, or
   Package Manager → Add package from disk → `com.maba.upscaler/package.json`.
2. Add **Component → MABA → MABA Upscaler** to the camera that renders your scene.
3. Play. Inspector: mode, sharpness, target fps, temporal, debug overlay.

URP is optional: the package has no hard dependency on it. With URP installed, the temporal
tier turns on the camera's depth texture for you.

Screen-space Overlay UI is drawn by Unity after the camera, at native resolution — keep your
UI in Overlay mode (or a separate overlay camera) so it is never upscaled.

## How it works

The component points `camera.targetTexture` at a fixed-size render texture allocated once at
0.77 scale, and sets `camera.pixelRect` to the current render size each frame, so the scene
(including URP post-processing and tonemapping) renders into a sub-region — no reallocation
when the scale changes. After the camera finishes (`OnPostRender` in the built-in pipeline,
`RenderPipelineManager.endCameraRendering` in URP) the region is upscaled to the screen.

The shaders live in `Runtime/Resources/MabaShaders` so player builds always include them. On
hardware without texture gather (OpenGL ES 3.0) the gather-free fast shader is used for every
rung.

Dynamic mode is driven by `FrameTimingManager` GPU time where the device supports it, and by
frame time otherwise. The controller is a line-for-line port of `maba_upscaler.h` and is
parity-tested against the C header on the host (20,000-frame trace, identical output).

Temporal mode additionally jitters the camera projection (Halton 2/3, 16 phases), keeps a
ping-pong history and previous-depth buffer at render resolution, and resolves before the
upscale. Depth is copied each frame and converted from the platform convention (reversed-Z on
Vulkan / Metal / D3D) to the 0-near..1-far depth the resolve expects. Reset happens
automatically on scale changes and first frame; call `ResetHistory()` on camera cuts.

## Runtime API

```csharp
var maba = camera.GetComponent<Maba.MabaUpscaler>();
maba.mode = Maba.MabaUpscaler.Mode.Balanced;
maba.sharpness = 0.5f;
maba.targetFps = 60f;
maba.temporal = true;   // MABA-Upscaler 2 (Temporal)
maba.ResetHistory();    // after a camera cut / teleport
```

## Limitations (read these)

- Spatial MABA is sharper than bilinear and softer than native. It adds no anti-aliasing;
  the temporal tier does, at a small cost.
- Verified by shader compilation (glslc HLSL front end, `test/compile_shaders.ps1`), host
  parity tests and a compile of the C# against stub Unity types. **Not yet run inside the Unity editor on a device** —
  report results, especially on Adreno and PowerVR. Things to check first on a real device:
  image orientation of the final blit, and that the depth texture is available in your URP
  asset when using the temporal tier.
- In a Linear colour-space project the scene texture is sampled as linear values, so the
  sharpening / dark-fade thresholds act on linear rather than gamma colour. Gamma projects
  match the reference exactly.
- Camera stacking: attach to the base camera only. Overlay cameras render after it, native.
- Region rendering requires the camera to own its target; do not also assign
  `camera.targetTexture` yourself.
- The temporal tier needs a depth texture (`DepthTextureMode.Depth` is set automatically; in
  URP the camera's "Depth Texture" option is switched on).

## Licence

Apache-2.0, Copyright 2026 MABA Studios. The quality kernel is derived from AMD FidelityFX
Super Resolution 1.0 (MIT); `NOTICE` and `THIRD_PARTY_NOTICES.md` are included in the package
and must accompany redistribution. Not affiliated with or endorsed by AMD.