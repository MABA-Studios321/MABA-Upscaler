# Changelog

## Unreleased - MABA Frame Gen (2x) prototype, and fixes from the 2026-11-13 code review

- **Engine plugins are labelled PRE-ALPHA** (metadata and READMEs: Unity `2.0.0-pre.1`, Unreal
  `2.0.0-pre-alpha` flagged Experimental, Godot `2.0.0-pre-alpha`). Each README gained a game-developer
  guide: integration checklist, saving player settings, starting points per device class, situations
  to handle, packaging notes, file map and FAQ. Unreal gained `Reset Maba History` (compiled on 5.6).
  Godot: the shaders are now loaded as imported `RDShaderFile` resources with `#[versions]`; the
  previous runtime read of the `.glsl` text silently did nothing in an exported game (found by
  exporting and running a `.pck`). Godot only applies a version's defines where the shader contains
  the `VERSION_DEFINES` token (without it the Balanced / quality build was silently the fast build).
- **Engine plugins: temporal tier everywhere, real controls, real verification (2026-11-15).**
  - *Godot addon now runs, and has the temporal tier.* It was desk-checked only before; running it on
    Godot 4.7 found three errors that would have stopped it loading: `Viewport` has no `compositor`
    property (the effect is now attached to the current `Camera3D`'s `Compositor`),
    `RenderingDevice.CULL_MODE_DISABLED` does not exist (`POLYGON_CULL_DISABLED`), and the effect's
    destructor could not call its own methods (a `release()` method frees the GPU objects). New:
    temporal resolve (`shaders/maba_temporal.glsl`, depth + matrix reprojection, point-sample
    accumulation) with camera frustum-mode jitter, `MabaTemporal` jitter sequence, `get_status()`,
    `scale_changed` signal, `show_stats`, `set_temporal()` / `set_sharpness()` / `reset_history()`,
    inspector warnings (`@tool`), **Project > Tools** menu (add node, check setup, apply recommended
    tonemap), an interactive demo, and `integrations/godot/test/run_godot_tests.ps1` (headless
    self-test + GPU render test against a supersampled reference). The jitter is only applied while
    the resolve is confirmed running; before that guard, a failed resolve left the camera shaking.
    Measured, one GPU and scene: bilinear 28.26 dB, spatial 27.36, temporal 27.51 (static) and
    -0.3 dB vs spatial while the camera moves; a bilinear shifted read lost 1.1 dB, so the resolve
    accumulates each texel's own sample.
  - *Unreal plugin compiles, and has the temporal tier.* Compiling it for the first time found that the
    release did not build on UE 5.6 (`FSceneView::ViewRect` is on `FViewInfo`); fixed. It now builds
    with UnrealBuildTool + UnrealHeaderTool on **UE 5.6 and 5.8**. New: temporal resolve
    (`Shaders/MabaTemporal.usf`, SM5, reversed-Z, double-precision current-to-previous clip matrix,
    per-view history), projection jitter in `SetupView`, taking views out of the engine TAA / TSR
    (`r.Maba.OverrideAntiAliasing`: with TSR the engine upscaled before MABA and MABA saw nothing to
    do), `r.Maba.Temporal*`, `r.Maba.ShowStats`, a **Project Settings > Plugins > MABA Upscaler** page
    (`UMabaSettings`), Blueprint nodes and `FMabaUpscalerModule::GetStatus()`. The plugin is now
    flagged Beta. Never run in a game.
  - *Unity package:* `historyWeight` / `clipGamma` / `depthTolerance` fields, a read-only status API
    (`RenderScale`, `Rung`, `RenderSize`, `IsNative`, `QualityKernel`, `TemporalRunning`, `CurrentFps`,
    `GpuMs`), `ScaleChanged`, `SetMode()`, a custom inspector (preset buttons, range slider, live
    status, setup warnings), a **Tools > MABA Upscaler** menu, an Editor assembly. Compile-checked
    against stub Unity types only; never run in Unity.
  - *Shared HLSL temporal core:* `MABA_REVERSED_Z` and `MABA_Y_DOWN` options (Unreal); the defaults
    leave Unity unchanged. `compile_shaders.ps1` now covers 46 variants (Unreal temporal, the Unreal
    configuration of the core, the Godot temporal shader).
  - *Docs and tooling:* each plugin has a full implementation README (install, quick start, settings
    reference, API, recipes, troubleshooting, an explicit verification status), copied into the plugin
    folder by `test/sync_hlsl.ps1`, which now also syncs `maba_temporal.h` into the Unreal plugin and has
    a `-Check` mode that `run_host_tests.ps1` runs.
- **Frame Gen no longer forces VSync; the Dynamic ladder is no longer capped; audit pass
  (2026-11-14).**
  - *VSync and Frame Gen decoupled.* The test app's swap interval follows the user's VSync setting
    alone (it used to be forced to the panel's whenever Frame Gen ran, which held real frames to
    half the refresh rate). Uncapped on a 60 Hz panel the overlay reads
    `REAL x + GENERATED y = OUTPUT z fps (panel shows 60)`; the platform still discards an
    arbitrary share of frames the panel cannot show, so the cadence is less even than with VSync
    on. Removed the `fguncapped` extra (Frame Gen is uncapped whenever VSync is off).
    *Found by measuring:* even with nothing forcing VSync, about one launch in three (11 of 34)
    stayed locked to the panel with Frame Gen on (30 real + 30 generated = 60 fps, never
    recovering) although `eglSwapInterval(0)` had returned success on the first frame - the
    request is not always honoured when made once. The interval is now asserted again on a
    back-off schedule (frames 3, 7, 15, 31, ... then every 240) and after every change of the
    setting or the surface; with the request repeated, 0 of 16 launches of the final build stayed
    locked (the single-request control, extra `vsyncreassert 0`, in the same session: 5 of 12).
    Cause not identified; this is a workaround found by experiment, on one device.
  - *No render-scale cap for a hardware class.* The Dynamic ladder grew from 29 rungs
    (0.50-0.77) to rungs -15..51 (0.35-1.00 in 1% steps); rung 51 is native and skips the upscale
    pass (`MabaFrame.isNative`). `MabaSetScaleRange()` narrows it (fixed presets ignore it);
    `MabaMaxRenderSizeFor()` sizes the render target for a range. Ports: Java, C#, GDScript;
    Unity `minScale` / `maxScale`, Unreal `r.Maba.MinScale` / `r.Maba.MaxScale`, Godot
    `min_scale` / `max_scale`.
  - *Headroom-aware step up.* After 180 good frames Dynamic climbs by as many rungs as the
    measured frame time predicts will fit (`avg * (p / p0)^2 <= 90%` of the budget, at most 16
    rungs); a failed climb returns to the rung it started from in one step. Back-off and proof
    constants are unchanged. On the test phone at a 30 fps target it climbed 0.59 -> 0.99
    (before, it stopped at 0.77). Verified by new C tests and a 55,000-frame trace that is
    identical across C, Java and C#; the GDScript port is desk-checked only.
  - *Frame Gen resolution independence.* The probe radius scales with the render height
    (`MABA_FG_REF_HEIGHT` 480, `MABA_FG_SCALE_MASK`, `uMabaFgParams.w`). Host test at 1x / 2x / 3x
    the reference height: all object scenes pass with the radius scaled, fast movers lose 35
    pixels (2x) and 714 pixels (3x) with it fixed. Only the radius scales: scaling the edge
    threshold or the validity tolerance too was measured neutral to slightly worse on the device
    (22.5 -> 22.1 dB). On the test phone's 720-line Native the change is quality-neutral, so the
    benefit is for higher resolutions and is verified on the host only.
  - *Test app.* Settings: Dynamic target 30-240 fps, render-scale range, thermal-limit switch.
    The thermal clamp used to cut the target at MODERATE status without saying so; it now caps
    it at 30 fps at SEVERE only, logs it, and can be switched off. Fixed: a `rung < 0` sentinel that
    collided with the new negative rungs, the Frame Gen benchmark skipping Native, the native
    controller freed only by its finalizer (now released in `onDestroy`), stale supersample / SR
    target ids after a context loss, per-frame `getIntent()` lookups, a GPU-timer query ring that
    leaked when the surface was re-created. Efficiency: uniform locations are cached per program
    (48 per-frame driver lookups with marshalled strings removed), one vertex array per mesh
    instead of four attribute calls per draw, allocation-free temporal state.
  - *Engines.* Unity: the scene texture was sized for the old 0.77 ceiling and silently clamped
    the render region; it is now sized from the range (or a preset's own rung), allocated only
    when a frame needs it (a game that stays at native never pays for it) and re-sized after the
    controller moves. Unreal: the pass is not subscribed at 100% on UE 5.5+ (no needless
    full-screen copy) and `r.ScreenPercentage` is restored on shutdown. Godot: range options.
    `MabaHalton` guards base < 2 in every port.
  - *Tools.* New `test/run_host_tests.ps1` (every host test plus the three-way controller parity;
    Frame Gen is built for three render heights); `compile_shaders.ps1` now covers 42 variants
    (the Frame Gen switches included). Docs: the stale "tile passes" note in `maba_framegen.h`
    and the forced-VSync text in the README.
- **Temporal SR: output-resolution temporal upscaling (2026-11-14).** New
  `src/maba_temporal_sr.frag.glsl` (resolve pass + sharpen "present" pass). The quality check now
  reports PSNR and "detail kept" for all four preset scales and for a plain native render
  (`--ei qsweep 1`), and showed the old Temporal tier keeping only 75-90% of the detail and not
  beating bilinear. Temporal SR accumulates at output resolution with weighted history, a depth
  test that only applies to moving pixels (always-on, it rejected history at every thin edge), and
  a wide bilinear-like prior blended by confidence. Measured against a 2x-supersampled render at
  sharpness 0.5: calm scene +1.2 to +2.3 dB over the old tier at every scale (0.59: 23.05 ->
  24.69 dB, above a native render's 24.82 at 0.67 and up), detail kept 96-100% instead of 79-92%;
  moving scene +0.1 to +0.8 dB, detail kept 99% instead of 75-89%. Cost: +5-7 ms over the old
  tier (uncapped 62.1 -> 47.9 fps on the calibrated scene); a first version cost +18 ms, cut by
  reading a 2x2 texel block and a bilinear history (0.00-0.02 dB moving, -0.27 dB calm). GLSL
  ES 3.0 only, Android test app only; not ported to the Unity / Unreal / Godot integrations and
  without a host test. The quality check also no longer carries accumulators over between runs.
  New dev extras: `qsweep`, `qtf`, `tsr`, `tsrr`, `tsrrw`, `tsrprior`, `tsrwmax`, `tsrk`,
  `tsrtaps`, `tsrhist`, `tsrhp`, `tsrsharp`. `compile_shaders.ps1` now covers 38 variants.
- **What the panel really shows (found by measuring, 2026-11-14).** The test phone's display has
  a single 60 Hz mode, so frame rates above 60 can never be seen; the overlay's uncapped
  "shown" figures counted frames the GPU finished (75.5 fps counted while 60.1 were displayed).
  New `test/android/panel_fps.ps1` reads SurfaceFlinger's record of displayed frames and
  reports frames per second and how evenly they are spaced for every mode, Frame Gen off/on.
  Measured on the glass (VSync on): Native 32.4 -> 49.0 fps (+51%), Ultra 43.4 -> 59.3 (+37%,
  62% -> 99% evenly spaced), Quality 51.2 -> 59.8, Balanced and Performance already 60. The
  earlier "+15-49%" and the "fixed 5-6 ms per window frame" explanation are withdrawn (README,
  "Where a pair's GPU time goes"): that was an interval artefact. New
  `test/android/gpu_slots.ps1` reads each Frame Gen slot's GPU time from SurfaceFlinger's frame
  completion times (panel-independent): a presented copy costs 0.8 ms, the warp slot 7.7 ms at
  Native (smooth path ~3.2, probe ~1.8, edge search ~2.5), the real frame ~3 ms more than a
  normal one. The warp's centre velocity is read once instead of twice (-0.5 ms, bit-exact).
  `MABA_FG_PROBE_TAPS` (default 8) is a new documented option: 4 taps cut the slot to 5.3 ms
  but lose leading-edge pixels of 10-texel diagonal movers (new host test, with a regression
  guard for the 8-tap default).
- **Frame Gen paces to the panel.** Uncapped on a fixed-refresh panel the platform discards an
  arbitrary share of real and generated frames, so Frame Gen now always presents with VSync;
  SHOWN is exact. Without Frame Gen, uncapped output above the panel's rate is labelled
  "N fps rendered, panel shows 60". (Superseded the same day: the forced VSync is gone, Frame
  Gen follows the VSync setting; see the first entry.)
- **Frame Gen at native resolution.** Offered in Native mode (it was excluded). Real frames
  render at full size (Frame Gen targets are screen-sized, `upscale` takes the source texture
  size, rung -1 means scale 1.0) and the warp writes the window directly. A guard makes the
  direct write apply only to a screen-sized real frame, so a stale smaller size can never leave
  a picture in one corner of the window.
- **Start-up stutter removed.** The image-quality checks cost 3.4 s of low frame rate (16
  frames over 45 ms, worst 142 ms) at every launch; they now run on demand (settings button
  "Run image-quality check", or `--ei qcstart 1`). Start-up ends with one 0.2 s hitch.
- Dev extras: `fgdbg`, `fguncapped` (since removed), `qcstart`. Host tests, 36 shader variants
  and the Android build pass.
- **Uncapped and faster test app.** VSync off by default (setting to turn it back on); targets
  30/60/90/120 fps; Dynamic uses real frame times when uncapped. Fixed a ~9% frame-rate
  regression at low resolution (Frame Gen work made the scene build every matrix twice and
  allocate ~260 objects per frame even with Frame Gen off; now allocation-free and only when
  motion vectors are needed). The sky is drawn after the scene at the far plane, so it is shaded
  only where it is visible; point lights and the pillar lookup are skipped where they cannot
  contribute. Measured against the previous build on the same phone: Performance 0.50 87/73 fps
  vs 68/68, Native 35/31 vs 31/30. The benchmark now measures on screen with VSync off
  (off-screen glFinish timing was distorted by fixed driver latency and by overlapped frames),
  and the live probe removes the measured latency: Dynamic at a 60 fps target now runs at 0.58
  instead of 0.51 render scale. Frame Gen's honest on-screen gain is +7-26% shown fps.
  (Superseded: those are presented-frame counts with VSync off; see the 2026-11-14 entry above
  for what the 60 Hz panel actually displayed.)
- **Upscaler and Temporal quality, found by an objective measurement and fixed.** New on-device
  check against a 2x-supersampled render (PSNR) for bilinear, MABA fast, MABA quality and
  Temporal. It showed Temporal 4 dB BELOW spatial (18.56 vs 22.43 dB) and the quality build
  below bilinear. Fixes: Temporal now un-jitters the current frame (+2.7 dB; new `uMabaJitter`,
  HLSL `jitter` argument, Unity `_Jitter`, host test), reprojects with per-object motion vectors
  (`MABA_TEMPORAL_VELOCITY`, +1.9 dB; the scene writes jitter-free velocity and the sky follows
  the jitter), distrusts history on moving pixels (`MABA_TEMPORAL_MOTION_K` 4), optional
  Catmull-Rom history (`MABA_TEMPORAL_SHARP`); quality build gain halved
  (`MABA_QUALITY_GAIN` 0.5, in GLSL, HLSL, both Godot ports and the CPU reference). Result:
  Temporal 22.26 dB animated / 23.05 dB calm, quality build 22.27 dB. Jitter sign convention
  documented in `maba_temporal.h` and corrected in the Unity component. Developer extras for
  the harness: qcfast, tfreeze, tnoshade, thw, tgamma, tdepth, tmk, tvel, tsharp, qlo, qhi,
  qgain, sharp.
- **Start-up smoothness and objective quality checks.** The benchmark no longer inserts a
  calibration frame (50-75 ms hitch) at every step, runs each mode once, and the quality checks
  (new: an upscaler-versus-native PSNR measurement next to the Frame Gen one) run one sub-step
  per frame on a centre crop instead of freezing the app for 1.6 s. `HITCH` log lines report
  any frame over 45 ms and what the app was doing. Framebuffer invalidation (no load of targets
  that are fully overwritten, no store of unused depth) added as standard tiled-GPU practice; it
  made no measurable difference on the test phone. Measured and documented: a fixed ~5-6 ms cost
  per frame that writes real content to the window, which is why Frame Gen cannot reach 2x here
  (README, "Why it is not 2x"). (Superseded: that explanation was measured on frames shorter
  than one refresh and is withdrawn; the cost is real but its cause is not identified.)
- **Frame Gen made cheaper.** The separate tile / dilation pre-pass is gone: the warp probes its
  own neighbourhood (8 taps), so a generated frame is one pass instead of two. Measured on the
  phone (on screen, VSync off, two rounds): the real+generated pair is 3-4 ms shorter in every
  preset (Balanced 29.0 -> 25.3-26.0 ms) and shown fps versus no Frame Gen rises from +7-26% to
  +15-49%; image quality is identical (25.3 dB this scene, 22.0 dB at 6x motion, vs 22.5 / 15.4
  for repeating the last frame). A real frame with the motion-vector output costs the same as a
  normal frame. The `FGBENCH` debug extra (`--ei fgbench 1|2`) times real-only or generated-only
  frames on screen.
- **MABA Frame Gen (2x), prototype** (Android test app): optional, off by default, a
  "MABA Frame Gen" button in the top-right corner. Extrapolated frame generation from colour,
  depth and per-pixel motion vectors (camera, objects and sky); a real frame is never held back.
  New `src/maba_framegen.frag.glsl` (two passes) and `src/maba_framegen.h` (slot policy and
  honest counters, used on the device through JNI). The overlay shows real, generated and
  shown fps counted from presented frames, refreshed once per second; the start-up chart
  becomes real -> shown fps while Frame Gen is on, and an on-device check compares generated
  frames with true renders. Measured results and limits: README, section "MABA Frame Gen".
  New host test `test/native/test_framegen.c`; `compile_shaders.ps1` covers the new shaders.

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
