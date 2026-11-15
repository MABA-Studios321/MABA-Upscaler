# MABA Upscaler for Unity

> ## Status: PRE-ALPHA
> This plugin is in **pre-alpha**: the API, setting names and defaults can still change without notice,
> it has had little real-world testing, and it is not ready to ship in a production game. Use it to
> evaluate, experiment and report problems. What has and has not been verified is spelled out in the
> *Verification status* box below. Issues and results from your own projects are very welcome.
Render the camera at a lower resolution, let MABA upscale and sharpen it to the screen in one cheap
pass, and (optionally) let the **MABA-Upscaler 2 (Temporal)** tier remove shimmer and jagged edges.
Built for low-end mobile GPUs, not tied to any hardware class: Dynamic mode uses the whole
0.35 - 1.00 render-scale range.

| | |
|---|---|
| Unity | 2021.3 or newer |
| Pipelines | Built-in and URP (URP is optional, there is no hard dependency) |
| Package | `com.maba.upscaler` 2.0.0 |
| Cost | one fragment pass for the upscale; the temporal tier adds two light passes at render resolution |

- **Presets:** Dynamic, Ultra Quality (77%), Quality (67%), Balanced (59%), Performance (50%).
- **Dynamic mode** holds a target frame rate by moving the render scale in 1% steps over the whole
  ladder, climbing several steps at once when the measured frame time says they fit. At 1.00 the
  camera renders straight to the screen and the upscale pass is skipped.
- **Temporal tier** (off by default): jittered accumulation with depth reprojection and a YCoCg
  neighbourhood clamp. Anti-aliasing and stability for about 1 - 3 ms on a low-end phone.
- **Editor tooling:** a custom inspector (preset buttons, range slider, live status, setup warnings)
  and a **Tools > MABA Upscaler** menu.

> **Verification status, read this first.** The shaders compile (glslc's HLSL front end), the C#
> controller is parity-tested against the C header (55,000-frame trace), and the runtime and editor
> C# compile against stand-in Unity types. **It has not been run inside the Unity editor or on a
> device**, because no Unity install was available to the author. Everything below describes the
> intended behaviour; please report what you see, especially on Adreno, PowerVR and Apple GPUs.

---

## 1. Install

1. Copy the `com.maba.upscaler` folder into your project's `Packages/` folder, **or** open
   *Window > Package Manager > + > Add package from disk...* and pick
   `com.maba.upscaler/package.json`.
2. Select your scene camera and use **Tools > MABA Upscaler > Add to Main Camera** (or
   *Add Component > MABA > MABA Upscaler*).
3. Press Play. In the Game view you should see the scene rendered at the chosen scale and upscaled
   to the window. Tick **Debug Overlay** to see mode, scale, fps and GPU time in a corner label.

The first time the package imports, Unity compiles two assemblies: `MabaUpscaler.Runtime` and
`MabaUpscaler.Editor` (editor only, not included in player builds).

### URP and the Built-in pipeline

- **Built-in:** nothing to configure. The upscale runs in `OnPostRender`.
- **URP:** nothing to configure for the spatial tier. The upscale runs from
  `RenderPipelineManager.endCameraRendering`. For the temporal tier the component switches on the
  camera's **Depth Texture** for you (and puts your setting back when the tier stops).
- Keep your UI in **Screen Space - Overlay** (or on a separate overlay camera). Overlay UI is drawn
  by Unity after the camera at native resolution, so it is never upscaled.
- Attach the component to the **base camera only**. Overlay cameras in a URP camera stack render
  after it, at native resolution.
- Do not also assign `camera.targetTexture` yourself: MABA owns it while the component runs.

---

## 2. Quick start recipes

**A fixed preset, no surprises**

Set *Mode* to *Balanced* (59%). That is a good default for weak GPUs.

**Hold 60 fps automatically**

Set *Mode* to *Dynamic*, *Target FPS* to 60. Optionally narrow the range with *Scale range* (for
example never below 0.5 so the image never gets too soft).

**Hold 30 fps on a phone and save battery**

*Mode* Dynamic, *Target FPS* 30, *Max* 1.0. The controller drops to whatever scale holds 30 and
climbs back when there is headroom.

**Anti-aliasing for free-ish**

Turn **Temporal** on. At 0.59 scale it removes the stair-stepping and the shimmer on thin lines for
about 1 - 3 ms on a low-end phone. It needs a depth texture and works best when the camera moves
smoothly. Call `ResetHistory()` on a camera cut.

---

## 3. Settings reference

### Upscaler

| Setting | Default | Range | What it does |
|---|---|---|---|
| **Mode** | Dynamic | Dynamic / Ultra Quality / Quality / Balanced / Performance | Dynamic moves the render scale to hold the target frame rate. The others are fixed scales: 0.77, 0.67, 0.59 (quality kernel), 0.50 (fast kernel). |
| **Sharpness** | 0.5 | 0 - 1 | Sharpening strength. 0.5 is the measured sweet spot; the sharpening cannot ring or overshoot and fades out in near-black areas. |

### Dynamic mode (ignored by the fixed presets)

| Setting | Default | Range | What it does |
|---|---|---|---|
| **Target FPS** | 60 | 15 - 240 | The frame rate Dynamic mode holds. Changing it at run time is fine; it only resets the controller when the value really changes. |
| **Min Scale** | 0.35 | 0.35 - 1 | Dynamic mode never renders below this fraction of the screen resolution. |
| **Max Scale** | 1.0 | 0.35 - 1 | Never above this. 1.0 = native (no upscale pass). A lower Max also allocates a smaller render texture, which saves memory. |

### Temporal (MABA-Upscaler 2)

| Setting | Default | Range | What it does |
|---|---|---|---|
| **Temporal** | off | | Switches the tier on. Jitters the camera projection (Halton 2,3 over 16 phases), keeps a ping-pong history and depth, resolves at render resolution, then upscales. |
| **History Weight** | 0.9 | 0.5 - 0.98 | How much of the previous frame is kept. 0.85 - 0.95 is the useful band. Higher is steadier and ghosts more. |
| **Clip Gamma** | 1.25 | 0.5 - 3 | Width of the colour clamp around the current neighbourhood. Lower rejects ghosts harder, higher keeps more detail. |
| **Depth Tolerance** | 0.01 | 0.001 - 0.1 | Depth difference that rejects history at disocclusions. 0.005 - 0.02 is typical. |

### Debug

| Setting | Default | What it does |
|---|---|---|
| **Debug Overlay** | off | One-line label: mode, scale, kernel, fps, GPU ms (development only). |

---

## 4. The custom inspector and the menu

**Inspector**

- **Preset** buttons set the mode in one click, with a one-line hint for the selected preset.
- **Dynamic mode** foldout: Target FPS and a **Scale range** slider (Min and Max as one control).
  Greyed out while a fixed preset is selected.
- **Temporal** foldout: the switch, the three tuning values, and *Reset tuning to defaults*.
- **Status** (Play mode): live render scale and size, kernel, fps and GPU time, temporal running or
  not, and a *Reset temporal history* button.
- **Setup check**: yellow and blue boxes for things worth knowing (camera already has a Target
  Texture, XR, Linear colour space, MSAA with temporal, temporal on but not running, ...).

**Tools > MABA Upscaler**

| Item | Does |
|---|---|
| Add to Main Camera / Add to Selected Camera | Adds the component with Undo support. |
| Preset > ... | Sets the mode on every selected MABA camera (Undo supported). |
| Check Project Setup | Reports the render pipeline, every MABA component's findings, and cameras without MABA. |
| Open Documentation | Opens this README from the package. |

---

## 5. Runtime API

```csharp
using Maba;

var maba = Camera.main.GetComponent<MabaUpscaler>();

// Settings (all of them can change at run time)
maba.SetMode(MabaUpscaler.Mode.Balanced);   // or: maba.mode = ...
maba.sharpness  = 0.5f;
maba.targetFps  = 60f;
maba.minScale   = 0.5f;                      // Dynamic mode's range; fixed presets ignore it
maba.maxScale   = 1f;
maba.temporal   = true;
maba.historyWeight = 0.9f;  maba.clipGamma = 1.25f;  maba.depthTolerance = 0.01f;

maba.ResetHistory();                         // after a camera cut or teleport

// Read-only status
float scale   = maba.RenderScale;            // 0.35 .. 1.0
int   rung    = maba.Rung;                   // -15 .. 51 on the 1% ladder
Vector2Int px = maba.RenderSize;             // this frame's render region
bool  native  = maba.IsNative;               // true: camera renders straight to the screen
bool  quality = maba.QualityKernel;          // 12-tap kernel in use
bool  running = maba.TemporalRunning;        // the resolve ran this frame
float fps     = maba.CurrentFps;
float gpuMs   = maba.GpuMs;                  // 0 where the platform reports no GPU time

maba.ScaleChanged += s => Debug.Log("render scale " + s);
```

### Recipe: a graphics-settings menu

```csharp
public void OnQualityDropdown(int index)   // 0 Dynamic, 1 Ultra, 2 Quality, 3 Balanced, 4 Performance
{
    maba.SetMode((MabaUpscaler.Mode)index);
}
public void OnTemporalToggle(bool on) { maba.temporal = on; }
```

### Recipe: a battery-saver switch

```csharp
// Lower the frame-rate target on demand (your own settings toggle, a thermal or battery signal from
// a platform plugin, ...). Dynamic mode follows within a second or two.
public void SetBatterySaver(bool on) { maba.targetFps = on ? 30f : 60f; }
```

### Recipe: camera cuts

```csharp
void Teleport(Vector3 p) { player.position = p; maba.ResetHistory(); }
```

---

## 6. How it works

The component points `camera.targetTexture` at a fixed-size render texture sized for the largest
scale the controller can ask for (`maxScale`, 1.00 by default; a fixed preset above it uses its
own), and sets `camera.pixelRect` to the current render size each frame. The scene, including URP
post-processing and tonemapping, renders into a sub-region of that texture, so changing the scale
never reallocates anything. After the camera finishes (`OnPostRender` in the built-in pipeline,
`RenderPipelineManager.endCameraRendering` in URP) the region is upscaled to the screen.

The texture is created the first frame it is needed, so a game that stays at native without the
temporal tier never allocates it. It is re-created if `maxScale` or the mode makes a larger one
necessary (history resets then). At `maxScale` 1.00 the texture is screen-sized (ARGB32 + depth, plus
the temporal tier's history): lower `maxScale` on memory-constrained devices.

The shaders live in `Runtime/Resources/MabaShaders` so player builds always include them. On
hardware without texture gather (OpenGL ES 3.0) the gather-free fast shader is used for every rung.

Dynamic mode is driven by `FrameTimingManager` GPU time where the device supports it, and by frame
time otherwise. The controller is a line-for-line port of `maba_upscaler.h`.

**Temporal tier, per frame**

1. The projection is shifted by a sub-texel jitter (perspective: the third column; orthographic:
   the translation column).
2. After the camera renders, the scene depth is copied into the current history-depth slot and
   converted to the 0-near..1-far depth the resolve expects (reversed-Z on Vulkan, Metal and D3D).
3. The resolve pass reads the jittered current frame (corrected by the jitter), reprojects the
   previous resolve with the camera matrices, rejects history where depth disagrees, clamps it to
   the local colour neighbourhood in YCoCg and blends.
4. The resolve is upscaled to the screen like any other frame.

History resets automatically on a scale change, a first frame and when the tier is switched off.
Call `ResetHistory()` on camera cuts.

---

## 7. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Black screen, error "upscale shader missing or unsupported" | The shaders were stripped or the device has no suitable shader level | Make sure the package folder is intact (`Runtime/Resources/MabaShaders`). Check the Console. |
| UI looks blurry | UI is rendered into the camera (Screen Space - Camera / World Space) | Use Screen Space - Overlay or an overlay camera. |
| Image is upside down or offset | A custom blit or a second component on the camera | Use one MabaUpscaler on the base camera; do not assign `targetTexture`. |
| Temporal is on but the Status says "not running" | No depth texture, or the depth copy shader was stripped | URP: the camera's Depth Texture option should read On (MABA switches it on); check the Console for a missing shader. |
| Ghost trails behind moving objects | History weight too high, objects without motion vectors | Lower History Weight to 0.85, Clip Gamma to 1.0. Reprojection uses camera motion only (no per-object motion vectors in this package). |
| Shimmering / crawling in a frozen scene | Temporal off | Turn Temporal on. |
| Frame rate does not rise in Dynamic mode | The frame is not GPU-bound, or VSync hides the headroom | Check *Status* for GPU ms. With VSync on, present-to-present time cannot see headroom, so Dynamic mode may settle a step lower than the GPU could hold. |
| Colours look different in a Linear project | Sharpening thresholds act on linear values | Tune Sharpness by eye; a Gamma project matches the reference exactly. |
| Memory use is high | The scene texture is screen-sized at Max Scale 1.0 | Lower Max Scale. |

---

## 8. Limitations

- Spatial MABA is sharper than bilinear and softer than native. It adds no anti-aliasing; the
  temporal tier does, at a small cost. On a PSNR measure against a supersampled reference the
  spatial tier scores about the same as bilinear: it trades fidelity for crispness.
- **Reprojection is camera-matrix only**: no per-object motion vectors in this package yet, so fast
  moving objects can ghost slightly; the depth test and the colour clamp keep it contained.
- Single view only. XR / multiview is not handled.
- Camera stacking: attach to the base camera only.
- The upscale resolves the finished LDR image, so HDR output is not supported.
- Not yet run in the Unity editor or on a device (see the box at the top).

---

## 9. Shipping it in a real game

### Integration checklist

1. Add the component to the **base** camera only; leave overlay / UI cameras alone.
2. Put UI in **Screen Space - Overlay** (world-space canvases render into the scene at render
   resolution, so their text gets softer at low scales).
3. Pick a default: a fixed preset for predictable visuals, or Dynamic with a `targetFps` that matches
   your game (30 for heavy mobile titles, 60 otherwise).
4. Add the settings to your options menu and **save them** (example below), then apply them at start-up.
5. Call `ResetHistory()` after camera cuts and teleports when Temporal is on.
6. Profile on a real device in a development build (`debugOverlay` shows scale, fps and GPU ms).
7. Re-check effects measured in pixels (bloom radius, outline width, FXAA/SMAA): they run at the
   *render* resolution, so they look different at 0.5 than at 1.0.

### Complete settings manager (PlayerPrefs)

```csharp
using Maba;
using UnityEngine;
using UnityEngine.SceneManagement;

public sealed class MabaSettingsManager : MonoBehaviour
{
    const string ModeKey = "maba.mode", TemporalKey = "maba.temporal", SharpnessKey = "maba.sharpness";
    MabaUpscaler maba;

    void Awake()
    {
        DontDestroyOnLoad(gameObject);
        SceneManager.sceneLoaded += OnSceneLoaded;
    }

    void OnDestroy() { SceneManager.sceneLoaded -= OnSceneLoaded; }

    // The camera usually changes with the scene: find it again, apply the saved settings, drop history.
    void OnSceneLoaded(Scene scene, LoadSceneMode mode)
    {
        maba = FindObjectOfType<MabaUpscaler>();
        if (maba == null) return;
        maba.SetMode((MabaUpscaler.Mode)PlayerPrefs.GetInt(ModeKey, (int)MabaUpscaler.Mode.Dynamic));
        maba.temporal = PlayerPrefs.GetInt(TemporalKey, 0) != 0;
        maba.sharpness = PlayerPrefs.GetFloat(SharpnessKey, 0.5f);
        maba.ResetHistory();
    }

    public void SetMode(int index)  { PlayerPrefs.SetInt(ModeKey, index);  if (maba) maba.SetMode((MabaUpscaler.Mode)index); }
    public void SetTemporal(bool on) { PlayerPrefs.SetInt(TemporalKey, on ? 1 : 0); if (maba) maba.temporal = on; }
    public void SetSharpness(float v) { PlayerPrefs.SetFloat(SharpnessKey, v); if (maba) maba.sharpness = v; }
}
```

### Starting points by device class (not benchmarks: measure your own game)

| Target | Suggested start |
|---|---|
| Low-end Android phone | Dynamic, `targetFps` 30 or 60, Min Scale 0.5, Temporal off |
| Mid-range phone | Dynamic, `targetFps` 60, Min Scale 0.6, Temporal on if the GPU has headroom |
| Handheld PC / low-end laptop | Balanced or Quality fixed, Temporal on |
| High-end desktop | Usually leave MABA off (or Ultra Quality) |

### Situations worth handling

| Situation | What to do |
|---|---|
| Pause menu (`Time.timeScale = 0`) | Nothing: the controller uses unscaled time. |
| Window or screen resolution change | Nothing: the scene texture is re-created when the screen size changes. |
| Loading screen or scene switch | `ResetHistory()` when the new scene's camera starts rendering. |
| Cutscene camera cuts | `ResetHistory()` on every cut. |
| Secondary cameras (minimap, render-to-texture) | Do not add MABA to them. |
| VSync on | Dynamic mode cannot see GPU headroom behind a vsync wait; it may settle a step low. |
| Targeting 30 fps | Set `Application.targetFrameRate = 30` **and** `targetFps = 30`. |

### Build and packaging notes

- The shaders live in `Runtime/Resources/MabaShaders`, so player builds always include them (no
  shader-variant collection needed). The package uses no reflection, so IL2CPP stripping is safe.
- The package needs OpenGL ES 3.0+ / Vulkan / Metal / D3D. OpenGL ES 2.0 is not supported.
- The Editor assembly (`MabaUpscaler.Editor`) is editor-only and is not in player builds.

## 10. File map (if you want to read or change the code)

| File | What it is |
|---|---|
| `Runtime/MabaUpscaler.cs` | The camera component: targets, per-frame controller, jitter, temporal and upscale passes, status API. |
| `Runtime/MabaController.cs` | Dynamic-resolution controller, a line-for-line port of `src/maba_upscaler.h`. |
| `Runtime/MabaTemporal.cs` | Halton jitter and reset state (port of `src/maba_temporal.h`). |
| `Runtime/Resources/MabaShaders/*` | Upscale (gather and no-gather), temporal resolve, depth copy. `MabaCore.hlsl` and `MabaTemporalCore.hlsl` are **copies** of `src/*.hlsl`: edit the source and run `test/sync_hlsl.ps1`. |
| `Editor/*` | Inspector, Tools menu, setup checks. |

## 11. FAQ

**Does it replace TAA / FSR / DLSS?** It is a separate, cheaper upscaler. Do not stack it with another
upscaler on the same camera. Its temporal tier gives anti-aliasing, not DLSS-class reconstruction.

**Why is it not sharper than native?** No upscaler can add detail the low-resolution render never
had. MABA aims to be cheap and clean, not to match native.

**Can I change everything at run time?** Yes. Mode, sharpness, target fps, range and temporal can all
change while playing (see section 5).

**Where do I report problems?** Open an issue with your Unity version, pipeline (Built-in / URP),
platform, GPU and the *Status* block from the inspector.
## 12. Licence

Apache-2.0, Copyright 2026 MABA Studios. The quality kernel is derived from AMD FidelityFX Super
Resolution 1.0 (MIT); `NOTICE` and `THIRD_PARTY_NOTICES.md` are included in the package and must
accompany redistribution. Not affiliated with or endorsed by AMD.
