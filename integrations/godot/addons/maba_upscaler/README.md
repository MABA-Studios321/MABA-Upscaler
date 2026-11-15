# MABA Upscaler for Godot

> ## Status: PRE-ALPHA
> This plugin is in **pre-alpha**: the API, setting names and defaults can still change without notice,
> it has had little real-world testing, and it is not ready to ship in a production game. Use it to
> evaluate, experiment and report problems. What has and has not been verified is spelled out in the
> *Verification status* box below. Issues and results from your own projects are very welcome.
Render your 3D scene at a lower resolution and let MABA upscale and sharpen it to the screen in one
cheap fragment pass, with an optional **MABA-Upscaler 2 (Temporal)** tier for anti-aliasing and
stability. Built for low-end mobile GPUs, not tied to any hardware class: Dynamic mode uses the whole
0.35 - 1.00 render-scale range. Built and maintained by **MABA Studios**.

| | |
|---|---|
| Godot | **4.7 tested.** Written against the 4.3 / 4.4 API too, but only 4.7 has been run |
| Renderers | Forward+ and Mobile (Vulkan). **Not** the Compatibility (OpenGL) renderer |
| Addon | `maba_upscaler` 2.0.0 |
| Cost | one fragment pass for the upscale; the temporal tier adds one pass at internal resolution |

- **Presets:** Dynamic, Ultra Quality (0.77), Quality (0.67), Balanced (0.59), Performance (0.50).
- **Dynamic mode** holds a target frame rate by moving the render scale in 1% steps over the whole
  ladder, climbing several steps at once when the measured frame time says they fit. At 1.00 the
  effect does nothing.
- **Temporal tier** (off by default): jittered accumulation with depth reprojection, camera-driven.
- **Editor tooling:** inspector warnings on the node, and three **Project > Tools** menu entries.
- A demo scene with keyboard controls, a headless self-test and a GPU render test.

> **Verification status.** On Godot 4.7 (Windows, Vulkan, Forward+, an RTX 5050) the headless
> self-test passes, an exported .pck runs the effect, the render test runs and measures quality against a supersampled reference, the demo
> scene runs without errors, and the editor loads the plugin without errors. **Not verified:** Godot
> 4.3 / 4.4, the Mobile renderer, any Android or iOS device, XR, and clicking the editor menu items
> (their logic is tested headless, the menus themselves were not clicked).

---

## 1. Install

1. Copy the `addons/maba_upscaler` folder into your project's `addons/` directory.
2. **Project > Project Settings > Plugins** > tick **MABA Upscaler**.
3. Open a 3D scene and use **Project > Tools > MABA Upscaler: add to open scene** (or add a
   **MabaUpscaler** node from the Create Node dialog). The scene needs a `Camera3D`.
4. Optional but recommended: **Project > Tools > MABA Upscaler: apply recommended settings**
   (sets the WorldEnvironment tonemap to Linear, exposure 1; undoable). See *Colour space* below.
5. Press Play. Tick **Show Stats** on the node to see mode, scale, fps and temporal state.

A demo scene is at `addons/maba_upscaler/demo/demo.tscn` (a spinning striped torus).

### What the node changes at run time

- It sets the viewport's `scaling_3d_mode` to **Bilinear** and drives `scaling_3d_scale` every frame
  (and puts both back when the node leaves the tree). Do not also enable FSR2 / FSR1 on the same viewport.
- It attaches its compositor effect to the **current Camera3D's `compositor`** (Godot keeps the
  Compositor on a camera or a WorldEnvironment, not on the viewport), keeps any effects already
  there, and follows the viewport if the current camera changes.
- With **Temporal** on it switches that camera into **frustum mode** with a sub-pixel offset each
  frame, and restores the camera when Temporal is turned off, the node leaves the tree, or the resolve
  cannot run. See section 6.

---

## 2. Quick start recipes

**A fixed preset:** *Mode: Balanced*.

**Hold 60 fps:** *Mode: Dynamic*, *Target Fps: 60*; narrow the range with *Min Scale* / *Max Scale*.

**Anti-aliasing at a low scale:** tick **Temporal**. Move the camera smoothly and call
`reset_history()` on a cut.

**Try everything interactively:** run the demo scene. Keys: `1`-`5` mode, `T` temporal, `R` reset
history, `S` cycle sharpness, `C` camera orbit, `H` stats label.

---

## 3. Settings reference (the `MabaUpscaler` node)

### Upscaler

| Property | Default | Range | What it does |
|---|---|---|---|
| `mode` | Dynamic | DYNAMIC / ULTRA_QUALITY / QUALITY / BALANCED / PERFORMANCE | Dynamic moves the scale to hold `target_fps`; the others are fixed (0.77 / 0.67 / 0.59 quality kernel / 0.50 fast kernel). |
| `sharpness` | 0.5 | 0 - 1 | Sharpening strength. The sharpening cannot ring or overshoot and fades out in near-black areas. |
| `convert_color_space` | on | | Wraps the MABA maths in a linear to gamma-2.2 conversion, because Godot's buffer is linear. Leave on. |

### Dynamic mode (ignored by the fixed presets)

| Property | Default | Range | What it does |
|---|---|---|---|
| `target_fps` | 60 | 15 - 240 | The frame rate Dynamic mode holds. |
| `min_scale` | 0.35 | 0.35 - 1 | Never renders below this fraction of the output resolution. |
| `max_scale` | 1.0 | 0.35 - 1 | Never above this; 1.0 = native. |

### Temporal (MABA-Upscaler 2)

| Property | Default | Range | What it does |
|---|---|---|---|
| `temporal` | off | | Switches the tier on. |
| `history_weight` | 0.9 | 0.5 - 0.98 | How much of the previous frame is kept. Higher is steadier and ghosts more. |
| `clip_gamma` | 1.25 | 0.5 - 3 | Width of the colour clamp that rejects ghosts. |
| `motion_k` | 4.0 | 0 - 16 | History is distrusted as a pixel moves: weight / (1 + K * motion in texels). |
| `depth_tolerance` | 0.01 | 0.001 - 0.1 | Relative depth difference that rejects history (disocclusion). |

### Debug

| Property | Default | What it does |
|---|---|---|
| `show_stats` | off | A corner label: mode, scale, kernel, fps, temporal state. |

---

## 4. The editor: warnings and menu

**Inspector warnings** (the yellow triangle next to the node in the scene tree). They appear when:
the renderer is Compatibility (error), the mobile renderer override is Compatibility, the scene has no
`Camera3D`, or a WorldEnvironment's tonemap is not Linear.

**Project > Tools**

| Item | Does |
|---|---|
| MABA Upscaler: add to open scene | Adds a `MabaUpscaler` node to the edited scene (undoable), then shows the setup report. |
| MABA Upscaler: check setup | Reports renderer, camera, number of MABA nodes, tonemap, glow / adjustments. |
| MABA Upscaler: apply recommended settings | Sets every WorldEnvironment to Linear tonemap at exposure 1 (undoable). |

The checks live in `maba_setup.gd` (`MabaSetup`), pure functions you can call from your own tools.

---

## 5. Runtime API

```gdscript
var maba: MabaUpscaler = $MabaUpscaler

maba.set_mode(MabaUpscaler.Mode.BALANCED)
maba.set_sharpness(0.5)
maba.set_target_fps(30.0)          # e.g. a battery-saver toggle or thermal throttling
maba.set_scale_range(0.5, 1.0)     # Dynamic mode's range; the fixed presets ignore it
maba.set_temporal(true)
maba.reset_history()               # after a camera cut or teleport
maba.submit_gpu_time(gpu_ms)       # optional, if you measure GPU time yourself

var s := maba.get_status()
# {mode, scale, rung, quality_kernel, native, frame_ms, fps, temporal_requested, temporal_running}

maba.scale_changed.connect(func(scale: float): print("render scale ", scale))
```

### Recipe: a graphics-settings screen

```gdscript
func _on_quality_option_selected(index: int) -> void:   # 0 Dynamic ... 4 Performance
    $MabaUpscaler.set_mode(index)

func _on_temporal_toggled(on: bool) -> void:
    $MabaUpscaler.set_temporal(on)
```

### Recipe: camera cuts and teleports

```gdscript
func teleport(to: Vector3) -> void:
    player.global_position = to
    $MabaUpscaler.reset_history()
```

### Recipe: your own post-processing

MABA runs as a `CompositorEffect` at `POST_TRANSPARENT`. Effects you add to the same camera's
compositor run in their list order; keep MABA last in that list (the node appends itself).

---

## 6. The temporal tier

**What it is for.** Anti-aliasing and stability at a low render scale: it removes stair-stepping on
edges and shimmer on thin lines. It accumulates at *internal* resolution, then the spatial upscaler runs
on the result. It does not recover detail the low-resolution render never contained.

**How it works, per frame**

1. The node computes the Halton(2,3) jitter (16 phases, the same sequence as `maba_temporal.h`) and
   switches the camera to frustum mode with the matching off-centre offset. In frustum mode with a
   zero offset the camera renders **pixel-identically** to the perspective camera (checked, 0 differing
   pixels); only your `fov`, `near`, `far` and `keep_aspect` are used, and they are re-read every
   frame, so scripts that change `fov` keep working.
2. The effect reads that jitter back from the frame's own projection matrix (no race between the node
   and the renderer), then resolves: this frame's colour, the scene depth, and last frame's resolve and
   depth go in; reprojection uses the renderer's camera matrices and the depth, history is rejected
   where depth disagrees, clamped to the local neighbourhood in YCoCg, blended.
3. Each texel's own point sample is accumulated (the standard TAA way). An earlier version read the
   jittered frame bilinearly at the shifted position and lost 1.1 dB of sharpness to the extra blur.
4. The result is upscaled like any other frame.

**Safety net.** The node only jitters the camera while the resolve is confirmed running (it probes for
six frames). If the resolve cannot run (no depth, a shader error, ...), jitter turns off and you get
the spatial result plus a warning, never a shaking image.

**Things to know**

- The camera is in frustum mode while Temporal is on. `Camera3D.unproject_position()` and friends see
  the sub-pixel jitter (up to half an internal texel).
- Orthographic cameras and cameras that already use frustum mode are left alone: Temporal then only
  stabilises, no jitter is added.
- Reprojection is depth + camera matrices (the same method as the Unity and Unreal packages). It
  needs only the depth buffer, so it should also work on the Mobile renderer (not verified; only Forward+ was run), but it does not use Godot's per-object **velocity buffer**: fast
  moving objects can ghost slightly. The depth test and the colour clamp contain it.
- History is dropped on a render-scale change (Godot recreates its internal buffers), a camera cut
  (`reset_history()`), and after a gap in rendering.

---

## 7. How the spatial pass fits Godot's pipeline

The last compositor callback is `POST_TRANSPARENT`. There, `get_color_texture()` is the **internal**
colour buffer at the scaled resolution, in **linear** space, before tonemapping. After that callback the
engine's tonemap pass runs and does the final internal to output resample (a bilinear stretch).

So the effect: (optionally) resolves temporal history, renders the MABA upscale from the internal
colour into its own **output-sized** texture, and blits that back over the internal colour. The engine's
tonemap then resamples it to the output.

**The one important caveat:** Godot has no post-tonemap compositor hook, so a compositor effect cannot be
the literal last pass. The image is resampled once more by the engine after MABA, which costs some
sharpening crispness compared with the Unity / Unreal packages (an engine limitation, not a shader
limitation). If a future Godot exposes a post-tonemap hook the effect can write straight to the output.

### Colour space

The core MABA maths expects a perceptual (gamma) LDR image. The internal buffer is linear, so the shader
converts around it (`convert_color_space`). For the round trip to be faithful use **tonemap Linear**
and **exposure 1** (the menu does this for you); other tonemap modes re-curve the image after MABA. HDR
values above 1 are clamped. Glow and colour adjustments run in the engine's tonemap pass, on MABA's
result.

### Timing source (honest)

Godot does not expose GPU timer queries to GDScript, so the node feeds the controller
**present-to-present frame time**. With vsync on, that cannot see GPU headroom, so Dynamic mode may
settle a step lower than the GPU could hold. If you have GPU time, pass it with `submit_gpu_time(ms)`.

---

## 8. `MabaUpscalerRect` (the SubViewport variant)

For projects that render 3D into a `SubViewport`: a full-screen `TextureRect` that sizes the SubViewport
from the controller and upscales its (already tonemapped) texture with `shaders/maba_canvas.gdshader`,
with no extra engine resample. Assign the SubViewport to `scene_viewport`. At scale 1.00 it drops the
shader and shows the viewport texture 1:1. **Spatial only**: the temporal tier belongs to the
`MabaUpscaler` node.

---

## 9. Measured, and how to run the tests

All numbers below are PSNR in dB against a 2x-supersampled reference, in the test scene
(`test/render_test.gd`: checker ground, striped boxes, thin poles, sphere), Balanced = 0.59 scale,
800 x 450 window, RTX 5050, Godot 4.7. **One GPU, one scene, one resolution**; treat them as a sanity
check, not as a benchmark.

| Configuration | PSNR |
|---|---|
| Plain bilinear at 0.59 | 28.26 |
| MABA spatial | 27.36 |
| MABA temporal, static camera (point-sample accumulation) | 27.51 |
| MABA temporal, shifted bilinear read (an earlier version) | 26.40 |
| Moving camera: spatial / temporal | 27.30 / 27.03 |

How to read it honestly: PSNR rewards blur, and the spatial upscaler trades fidelity for crispness (it
also pays for Godot's extra resample, section 7), so it scores below bilinear here. The temporal tier
anti-aliases the edges (the stair-stepping is gone in the images) and scores about 0.15 dB above
spatial on a calm scene; while the camera moves it is about 0.3 dB below spatial. It is an
anti-aliasing and stability tier, and it is not free.

**Run the tests** (Windows; needs a Godot 4 console executable):

```
powershell -ExecutionPolicy Bypass -File integrations\godot\test\run_godot_tests.ps1 -Godot <path\to\Godot_console.exe> [-Render] [-Moving] [-Save]
```

- Without `-Render`: the headless self-test (ladder, controller, multi-rung climbs, jitter sequence,
  setup checks). It prints `ALL GODOT CONTROLLER TESTS PASSED`.
- With `-Render`: opens a window, runs the quality measurement above (needs a GPU). `-Moving` adds
  the moving-camera comparison, `-Save` writes the images. The runner has a hard timeout and retries
  (`-TimeoutSeconds`, `-Retries`): on the author's machine Godot 4.7 now and then deadlocks at
  startup (0% CPU, right after loading its own shader cache, before any addon code runs), so roughly one
  run in five needs its second attempt.

---

## 10. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Warning "needs the Vulkan renderer" | Compatibility renderer | Project Settings > Rendering > Renderer: Forward+ or Mobile. |
| Nothing is upscaled | No current `Camera3D`, or `max_scale` is 1.0 and the controller reached native | Add a camera; check `get_status()["native"]`; try a fixed preset. |
| Image looks washed or too contrasty | Tonemap is not Linear | Menu: apply recommended settings. |
| Temporal shows "requested, not running" | No depth buffer, or a shader error | Read the warning in the Output panel; jitter is off meanwhile. |
| Ghost trails with Temporal | History too long | `history_weight` 0.85, `clip_gamma` 1.0. |
| Image shakes with Temporal | The resolve is not running but jitter is on | The node prevents this; if you see it, report the `temporal_fail_reason` of the effect. |
| FSR2 / TAA also on | Two temporal systems | Turn off the viewport's `use_taa` and FSR2 scaling mode. |
| Dynamic mode never climbs | vsync hides the headroom | See *Timing source*. |

---

## 11. Limitations

- Vulkan (Forward+ / Mobile) only; not Compatibility; single view only (no XR / multiview).
- The extra engine resample after MABA (section 7) softens the result a little more than in Unity / Unreal.
- Temporal: depth + camera reprojection only (no velocity buffer); orthographic and frustum cameras are
  not jittered.
- Only Godot 4.7 has been run; 4.3 / 4.4 are untested.

---

## 12. Shipping it in a real game

### Integration checklist

1. Install the addon, enable it, add the node (menu: *add to open scene*), run the setup check.
2. Use the **Forward+** or **Mobile** renderer; set tonemap **Linear**, exposure 1 (menu: *apply
   recommended settings*).
3. Pick defaults: a fixed preset, or Dynamic with a `target_fps` that matches your game.
4. Build the options screen and **save the player's choice** (example below).
5. Call `reset_history()` after teleports and camera cuts when Temporal is on.
6. Test an **exported** build, not only the editor (see *Exporting*).
7. Re-check effects measured in pixels: they run at the render resolution.

### Settings autoload with saving (ConfigFile)

Make this an autoload (*Project Settings > Globals > Autoload*). The `MabaUpscaler` node it creates
follows the viewport's current camera, so it survives scene changes.

```gdscript
extends Node

const PATH := "user://maba.cfg"
var maba: MabaUpscaler

func _ready() -> void:
    var cfg := ConfigFile.new()
    cfg.load(PATH)   # missing file: defaults below
    maba = MabaUpscaler.new()
    maba.mode = cfg.get_value("maba", "mode", MabaUpscaler.Mode.DYNAMIC)
    maba.temporal = cfg.get_value("maba", "temporal", false)
    maba.sharpness = cfg.get_value("maba", "sharpness", 0.5)
    add_child(maba)

func save_choice() -> void:
    var cfg := ConfigFile.new()
    cfg.set_value("maba", "mode", maba.mode)
    cfg.set_value("maba", "temporal", maba.temporal)
    cfg.set_value("maba", "sharpness", maba.sharpness)
    cfg.save(PATH)
```

### Starting points by device class (not benchmarks: measure your own game)

| Target | Suggested start |
|---|---|
| Low-end Android phone | Mobile renderer, Dynamic, `target_fps` 30 or 60, `min_scale` 0.5, Temporal off |
| Mid-range phone | Dynamic, `target_fps` 60, `min_scale` 0.6 |
| Desktop / handheld PC | Balanced or Quality fixed, Temporal on |
| High-end desktop | Usually leave MABA off |

### Exporting

The shaders are `.glsl` files that Godot **imports** (compiled to SPIR-V and packed into the export),
so nothing extra is needed in the export preset: keep the `addons/maba_upscaler` folder in the
project and do not exclude `*.import` / `.godot/imported`. This was tested by exporting a `.pck` and
running it (`--main-pack`): the effect loaded and the temporal resolve ran. (An earlier version read the
shader source text at run time, which silently did nothing in exported games; fixed.) Export templates
and a real Android export were **not** tested.

### Situations worth handling

| Situation | What to do |
|---|---|
| Pause (`get_tree().paused`) | The node keeps running; frame time is wall-clock, so a pause is not mistaken for GPU headroom. |
| Window resize | Nothing: Godot recreates the buffers, the history resets. |
| Camera cuts / teleports | `reset_history()`. |
| Several `Camera3D`s | MABA follows the current one and moves the effect with it. |
| SubViewport scenes | Use `MabaUpscalerRect` (spatial only). |
| Your own compositor effects | They run in list order on the same camera; MABA appends itself last. |

## 13. File map

| File | What it is |
|---|---|
| `maba_upscaler.gd` | The node: controller tick, scale, camera jitter, compositor attachment, stats, API. |
| `maba_compositor_effect.gd` | The `CompositorEffect`: temporal resolve, upscale and blit passes, GPU resources. |
| `maba_controller.gd` | Dynamic-resolution controller (port of `src/maba_upscaler.h`). |
| `maba_temporal.gd` | Halton jitter sequence (port of `src/maba_temporal.h`). |
| `maba_setup.gd` | Project / scene checks for the editor menu and inspector warnings. |
| `maba_plugin.gd` | The editor plugin (Project > Tools menu). |
| `maba_upscaler_rect.gd` | The SubViewport variant (spatial only). |
| `shaders/*.glsl` | Upscale (fast / quality versions), blit, temporal resolve. The `VERSION_DEFINES` token in `maba_upscaler.glsl` is where Godot inserts the selected version's defines: do not remove it. |
| `shaders/maba_canvas.gdshader` | Canvas shader for `MabaUpscalerRect`. |
| `test_controller.gd`, `../../test/` | Headless self-test and the GPU render test. |

## 14. FAQ

**Does it replace Godot's FSR2 / TAA?** It is a separate, cheaper upscaler. Do not run it together
with FSR2 or `use_taa` on the same viewport.

**Why is the image not as crisp as Unity / Unreal?** Godot resamples once more after MABA (section 7).

**Does Temporal need the velocity buffer?** No: depth and camera matrices only (section 6).

**Where do I report problems?** Open an issue with the Godot version, renderer, platform, GPU and the
node's `get_status()` output.
## 15. Licence

Apache-2.0, Copyright 2026 MABA Studios. MABA Studios is owned by Muhammad Affan Bin Adnan. The quality
kernel is derived from AMD FidelityFX Super Resolution 1.0 (MIT); see
`addons/maba_upscaler/THIRD_PARTY_NOTICES.md` and the repository `NOTICE` / `THIRD_PARTY_NOTICES.md`,
which must accompany redistribution. Not affiliated with or endorsed by AMD.
