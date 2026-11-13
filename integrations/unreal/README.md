# MABA Upscaler for Unreal Engine 5

Single-pass spatial upscaler for low-end mobile GPUs. The plugin hooks the post-tonemap point
of the post-processing chain and upscales the rendered scene (at `r.ScreenPercentage`
resolution) to output resolution in one cheap pixel-shader pass — the same integration pattern
as AMD's FSR1 mobile plugin, with a much cheaper shader.

- One pixel pass, no compute, no intermediate full-res target.
- Dynamic mode holds a target frame rate by moving `r.ScreenPercentage` in 1% steps
  (50-77%) with hysteresis and exponential back-off. The controller is the **real C header**
  (`maba_upscaler.h`), compiled into the plugin — not a port.
- Presets: Ultra Quality 77%, Quality 67%, Balanced 59%, Performance 50%.
- OpenGL ES 3.1 / Vulkan mobile feature level and up (SM5 desktop also works).

## Install

1. Copy `MabaUpscaler/` into your project's `Plugins/` folder.
2. Regenerate project files, build, enable the plugin if not enabled by default.
3. Set your project's mobile post-processing to include tonemap (default). Play.

Console variables:

| CVar | Default | Meaning |
|---|---|---|
| `r.Maba.Enable` | 1 | Upscale pass on/off |
| `r.Maba.Mode` | 0 | 0 Dynamic, 1 Ultra Quality, 2 Quality, 3 Balanced, 4 Performance |
| `r.Maba.Sharpness` | 0.5 | Sharpening strength 0..1 |
| `r.Maba.TargetFps` | 60 | Frame rate Dynamic mode holds |

UI is drawn by UMG after post-processing, at output resolution — never upscaled.

## How it works

`FMabaViewExtension::SubscribeToPostProcessingPass` hooks `EPostProcessingPass::Tonemap`; the
callback reads the tonemapped scene color (render resolution), runs the MABA pixel shader into
an output-resolution RDG texture (or the engine's override output when MABA is the last
pass), and returns it as the new scene color. A game-thread ticker runs the C controller and
writes `r.ScreenPercentage`; quality rungs (0.59 quality and up) use the 12-tap shader.
Setting `r.Maba.Enable 0` removes the pass and restores `r.ScreenPercentage` to 100.

## Limitations (read these)

- **Not yet compiled against a local engine** (no UE install on the development machine at
  release time). The hook API follows the UE 5.x `FAfterPassCallbackDelegateArray` signature,
  with guards for the 5.4 (texture slices) and 5.5 (view parameter) changes; build on 5.3-5.8
  and report issues. Validate on your target version first. The shader itself is
  compile-checked with glslc's HLSL front end.
- The view rect must start at (0,0) in the scene color texture (true for a normal game
  viewport); otherwise the pass falls back to the engine's own upscale.
- Spatial only in this integration. The **MABA-Upscaler 2 (Temporal)** tier ships in the
  Android test app and the Unity package; the UE version needs engine-side validation of
  projection jitter and persistent history buffers and is the next planned increment.
- Dynamic mode uses present-to-present frame time; under vsync it learns headroom by missing
  frames (same trade-off as FSR1's plugin). Feeding it UE GPU timing is a planned improvement.
- Sharper than bilinear, softer than native; no anti-aliasing in the spatial tier.

## Licence

Apache-2.0, Copyright 2026 MABA Studios. Quality kernel derived from AMD FidelityFX Super
Resolution 1.0 (MIT); `NOTICE` and `THIRD_PARTY_NOTICES.md` are included in the plugin folder
and must accompany redistribution. Not affiliated with or endorsed by AMD.