# MABA Upscaler for Unreal Engine 5

> ## Status: PRE-ALPHA
> This plugin is in **pre-alpha**: the API, setting names and defaults can still change without notice,
> it has had little real-world testing, and it is not ready to ship in a production game. Use it to
> evaluate, experiment and report problems. What has and has not been verified is spelled out in the
> *Verification status* box below. Issues and results from your own projects are very welcome.
Render the scene at a lower `r.ScreenPercentage`, let MABA upscale and sharpen it to the output in
one cheap pixel-shader pass, and (optionally) let the **MABA-Upscaler 2 (Temporal)** tier remove
shimmer and jagged edges first. Built for low-end mobile GPUs, not tied to any hardware class:
Dynamic mode uses the whole 35 - 100% render-scale range.

| | |
|---|---|
| Engine | UE 5.6 and 5.8 build cleanly (see *Verification status*); 5.4 / 5.5 have code guards but have not been compiled |
| Plugin | `MabaUpscaler` 2.0.0, marked **Beta** |
| Hook | post-processing chain, after the tonemapper (the same pattern as AMD's FSR1 mobile plugin) |
| Cost | one pixel pass for the upscale; the temporal tier adds one pass at render resolution |

- **Presets:** Dynamic, Ultra Quality 77%, Quality 67%, Balanced 59%, Performance 50%.
- **Dynamic mode** holds a target frame rate by moving `r.ScreenPercentage` in 1% steps with
  hysteresis, exponential back-off and multi-step climbs when the measured frame time says they fit.
  The controller is the **real C header** (`maba_upscaler.h`), compiled into the plugin, not a port.
- **Temporal tier** (off by default, SM5 only): jittered accumulation with depth reprojection.
- **Control surfaces:** Project Settings page, console variables, Blueprint nodes, C++ API, and an
  on-screen stats line.

> **Verification status, read this first.**
> - The plugin **compiles and links** (UnrealBuildTool + UnrealHeaderTool, Win64 Editor, Development)
>   on **UE 5.6** and **UE 5.8**. That compile found, and this version fixes, a real error in the
>   previous release (`FSceneView::ViewRect` does not exist on 5.6).
> - The shaders are compile-checked with glslc's HLSL front end (all variants), not by Unreal's own
>   shader compiler.
> - **It has not been run in a game.** The render passes, and above all the temporal tier
>   (jitter sign, history, depth reprojection), have never executed. Treat the first run as a test and
>   report what you see.
> - Only Windows (Win64 Editor) has been built. Android / iOS / consoles have not.

---

## 1. Install

1. Copy the `MabaUpscaler` folder into your project's `Plugins/` folder (create it if needed):
   `YourProject/Plugins/MabaUpscaler/MabaUpscaler.uplugin`.
2. Right-click your `.uproject` > *Generate Visual Studio project files*, then build the project
   (the plugin has C++ source, so a C++ toolchain is required: Visual Studio on Windows, Xcode on
   Mac, the NDK for Android).
3. Open the project. *Edit > Plugins > Rendering > MABA Upscaler* should be ticked (it is enabled by
   default). Restart if asked.
4. Open **Edit > Project Settings > Plugins > MABA Upscaler**, pick a preset, and press Play.
5. Open the console (`) and type `r.Maba.ShowStats 1` to see the mode, render scale, fps and temporal
   state on screen.

To ship a binary plugin to a team instead:

```
Engine\Build\BatchFiles\RunUAT.bat BuildPlugin -Plugin="C:\path\MabaUpscaler\MabaUpscaler.uplugin" -Package="C:\out\MabaUpscaler" -TargetPlatforms=Win64+Android -Rocket
```

### What the plugin changes in your project

- It owns **`r.ScreenPercentage`** while it is enabled (it sets it every tick from the controller) and
  puts it back to 100 when you turn it off or unload the plugin. Do not drive the screen percentage
  from game code at the same time.
- While MABA renders a view it takes that view **out of the engine's TAA / TSR** (they would upscale
  before MABA runs, and TSR would make the render and output sizes equal, so MABA would see nothing
  to upscale). This is `r.Maba.OverrideAntiAliasing` (default on). If you manage
  `r.AntiAliasingMethod` yourself, switch it off.
- At 100% scale MABA gets out of the way: the engine's own anti-aliasing is left alone and the pass
  is not subscribed at all (UE 5.5+).

---

## 2. Quick start recipes

**A fixed preset**

Project Settings > MABA Upscaler > *Mode: Balanced*.

**Hold 60 fps automatically**

*Mode: Dynamic*, *Target Fps: 60*. Narrow the range with *Min Scale* / *Max Scale* if you do not want
the image to get softer than, say, 50%.

**Switch it from a menu at run time (Blueprint)**

*Set Maba Mode* (Mode: Quality), *Set Maba Temporal* (true), *Set Maba Sharpness* (0.5). They set the
console variables with code priority, so they win over the Project Settings defaults.

**Switch it from the console**

```
r.Maba.Mode 3
r.Maba.Temporal 1
r.Maba.ShowStats 1
```

---

## 3. Settings reference

Every setting exists as a console variable (`r.Maba.*`). **Project Settings > Plugins > MABA
Upscaler** writes them at startup (priority: *project setting*); a variable set later from the
console, an ini `[SystemSettings]`, the command line or Blueprint/C++ wins.

| Console variable | Project Settings | Default | Range | What it does |
|---|---|---|---|---|
| `r.Maba.Enable` | Enabled | 1 | 0 / 1 | Master switch. Off removes the pass and restores `r.ScreenPercentage` to 100. |
| `r.Maba.Mode` | Mode | 0 | 0 - 4 | 0 Dynamic, 1 Ultra Quality (0.77), 2 Quality (0.67), 3 Balanced (0.59), 4 Performance (0.50). |
| `r.Maba.Sharpness` | Sharpness | 0.5 | 0 - 1 | Sharpening strength. |
| `r.Maba.TargetFps` | Target Fps | 60 | 15 - 240 | The frame rate Dynamic mode holds. |
| `r.Maba.MinScale` | Min Scale | 0.35 | 0.35 - 1 | Dynamic never renders below this fraction of the output. |
| `r.Maba.MaxScale` | Max Scale | 1.0 | 0.35 - 1 | Dynamic never renders above this; 1.0 = native. The fixed presets ignore the range. |
| `r.Maba.Temporal` | Temporal | 0 | 0 / 1 | MABA-Upscaler 2 (Temporal). SM5 / desktop-class renderers only. |
| `r.Maba.Temporal.HistoryWeight` | History Weight | 0.9 | 0.5 - 0.98 | How much of the previous frame is kept. Higher is steadier and ghosts more. |
| `r.Maba.Temporal.ClipGamma` | Clip Gamma | 1.25 | 0.5 - 3 | Width of the colour clamp that rejects ghosts. |
| `r.Maba.Temporal.DepthTolerance` | Depth Tolerance | 0.01 | 0.001 - 0.1 | Relative depth difference that rejects history. |
| `r.Maba.OverrideAntiAliasing` | Override Anti Aliasing | 1 | 0 / 1 | Take views out of the engine TAA / TSR while MABA renders them. |
| `r.Maba.ShowStats` | Show Stats | 0 | 0 / 1 | On-screen line: mode, scale, kernel, fps, temporal state. |

Presets at a glance: Ultra Quality 77%, Quality 67%, Balanced 59% (quality kernel), Performance 50%
(fast kernel). Dynamic walks the whole ladder from 35% (rung -15) to 100% (rung 51).

---

## 4. Blueprint and C++ control

**Blueprint** (category *MABA Upscaler*): `Set Maba Enabled`, `Set Maba Mode`, `Set Maba Sharpness`,
`Set Maba Target Fps`, `Set Maba Scale Range`, `Set Maba Temporal`, `Reset Maba History`, `Set Maba Show Stats`, and the pure
node `Get Maba Status`, which returns:

| Field | Meaning |
|---|---|
| `Active` | false when MABA is switched off |
| `Mode` | the preset in effect |
| `Render Scale` | 0.35 - 1.0 (1.0 = native) |
| `Rung` | position on the 1% ladder, -15 to 51 |
| `Quality Kernel` | the 12-tap kernel is in use |
| `Temporal Requested` / `Temporal Running` | asked for / the resolve really ran on the last frame |

**C++**

Add the module to your `Build.cs`:

```csharp
PublicDependencyModuleNames.Add("MabaUpscaler");
```

```cpp
#include "MabaBlueprintLibrary.h"
#include "MabaUpscalerModule.h"

UMabaBlueprintLibrary::SetMabaMode(EMabaMode::Balanced);
UMabaBlueprintLibrary::SetMabaTemporal(true);

const FMabaUpscalerModule::FStatus Status = FMabaUpscalerModule::GetStatus();
UE_LOG(LogTemp, Log, TEXT("MABA render scale %.2f, temporal running: %d"), Status.Scale, Status.bTemporalRunning);
```

### Recipe: a graphics-settings screen

Bind a dropdown to `Set Maba Mode` (the enum has the five presets), a checkbox to `Set Maba Temporal`
and a slider (0 - 1) to `Set Maba Sharpness`. Show the current scale in the HUD with `Get Maba Status`
> `Render Scale`.

### Recipe: lower the target while the device is hot

Call `Set Maba Target Fps` (30) from whatever thermal or battery signal your platform layer gives you;
Dynamic mode follows within a second or two.

---

## 5. How it works

`FMabaViewExtension` is a scene view extension.

1. **`SetupView`** (game thread): when MABA is on and the scale is below 100%, takes the view out of
   TAA / TSR (if `OverrideAntiAliasing`), and for the temporal tier adds a sub-pixel projection jitter
   with `HackAddTemporalAAProjectionJitter` (Halton 2,3 over 16 phases, the same sequence as the C
   header `maba_temporal.h`).
2. **`SubscribeToPostProcessingPass(Tonemap)`**: the callback runs after the tonemapper, on finished
   LDR gamma-space colour, which is MABA's contract. At 100% the pass is not subscribed at all (UE 5.5+).
3. **`UpscalePass`** (render thread):
   - *(optional)* the **temporal resolve** at render resolution: current colour + scene depth + the
     previous resolve and depth (kept per view in pooled render targets) go in, the new resolve and
     depth come out. Reprojection uses one matrix from this frame's clip space to the last one, built
     in double precision on the CPU, so large world coordinates do not cost float precision on the GPU.
   - the **upscale** into an output-resolution texture (or the engine's override output when MABA is
     the last pass), then it returns that as the new scene colour.
4. A game-thread ticker runs the C controller and writes `r.ScreenPercentage`. Quality rungs
   (0.59 quality and up) use the 12-tap shader; the lowest rungs use the fast one.

The shaders (`Shaders/`) are `MabaUpscale.usf` and `MabaTemporal.usf`, which include the shared cores
`MabaCore.ush` and `MabaTemporalCore.ush` (copies of `src/maba_upscaler.hlsl` and
`src/maba_temporal.hlsl`, kept in sync by `test/sync_hlsl.ps1`). The temporal core is configured for
Unreal: reversed-Z depth and matrices, screen rows running top to bottom.

---

## 6. The temporal tier

**What it is for.** Anti-aliasing and stability: it removes the stair-stepping on edges and the
shimmer on thin lines at a low render scale. It accumulates at *render* resolution, then the spatial
upscaler runs on the result. It is not a detail-recovering super-resolution tier.

**Requirements and behaviour.**

- SM5-class renderers (desktop D3D11/D3D12/Vulkan, Metal SM5 and consoles). It is skipped on
  ES3.1 mobile feature levels (no scene depth there): the spatial upscaler still runs.
- It takes the view out of the engine TAA / TSR (it provides its own AA), so it replaces them.
- It is only active while the render scale is below 100%. At native it does nothing and the engine's
  own AA applies.
- History is kept per view (so split-screen works) and resets on camera cuts, on a render-size change
  (Dynamic mode stepping), and after a gap in rendering.
- **Reprojection uses the camera and scene depth only**: there are no per-object motion vectors, so
  fast moving objects can ghost slightly; the depth test and the colour clamp contain it.

**Tuning.** Start with the defaults. Ghost trails: lower *History Weight* to 0.85 and *Clip Gamma* to
1.0. Too much shimmer: raise *History Weight* to 0.93.

---

## 7. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Plugin does not load, "module could not be loaded" | The project was not rebuilt | Generate project files and build the project in your IDE. |
| Compile error on another engine version | Only 5.6 and 5.8 have been compiled | The hook signatures changed in 5.4 (texture slices) and 5.5 (view parameter) and are guarded; send the error. |
| Image is blurry but fps goes up, no sharpening | The engine's TSR / TAA is upscaling, MABA sees nothing to do | Leave `r.Maba.OverrideAntiAliasing` on, or set `r.AntiAliasingMethod` to FXAA / None yourself. |
| Nothing changes with `r.Maba.Mode` | Plugin disabled or `r.Maba.Enable 0` | `r.Maba.ShowStats 1` shows "MABA disabled". |
| Screen percentage keeps jumping back | Another system writes `r.ScreenPercentage` | Remove it, or turn MABA off. |
| Temporal "requested, not running" | Mobile feature level, no view state, or the view is at 100% | See section 6. Check `LogTemp` for shader compile errors. |
| Shimmer / swimming only with temporal | A jitter or reprojection sign problem (never run yet) | Report it with the UE version and platform. |
| Shader compile error for `MabaTemporal.usf` | First run on this engine version | Send the full error from the shader compiler log. |
| UI looks soft | UI drawn into the scene | UMG draws after post-processing at output resolution; check the widget is not rendered to a render target. |

---

## 8. Limitations

- Spatial MABA is sharper than bilinear and softer than native; it adds no anti-aliasing (the
  temporal tier does).
- The view rectangle must start at (0, 0) in the scene colour texture (true for a normal game viewport);
  otherwise the pass falls back to the engine's own upscale.
- Dynamic mode uses present-to-present frame time; under vsync it learns headroom by missing frames
  (the same trade-off as FSR1's plugin). Feeding it Unreal's GPU timing is a planned improvement.
- Single view family per tick for the controller (split-screen shares one scale).
- Not run in a game (see the box at the top).

---

## 9. Shipping it in a real game

### Integration checklist

1. Install the plugin, build, confirm `r.Maba.ShowStats 1` prints the stats line.
2. Pick defaults in **Project Settings > MABA Upscaler** (they land in `Config/DefaultGame.ini`).
3. **Remove or hide the engine's resolution-quality scalability setting** from your options menu.
   `sg.ResolutionQuality` writes `r.ScreenPercentage`, which MABA owns while it is enabled.
4. Build an options screen with the Blueprint nodes (section 4) and save the player's choice.
5. After a teleport, level switch or custom camera cut call **`Reset Maba History`** when Temporal is on
   (engine camera cuts such as Sequencer and *Set Game Camera Cut This Frame* should reset it on their own).
6. Profile on the target device with `stat gpu` / `ProfileGPU`: the passes show up as "MABA Upscaler",
   "MABA Temporal" and "MABA Upscale ... -> ...".
7. Re-check effects measured in pixels (bloom, outlines): they run at the render resolution.

### Saving the player's choice (C++ sketch)

```cpp
// MyGameInstance.cpp: apply the saved choice at start-up.
#include "MabaBlueprintLibrary.h"
#include "Misc/ConfigCacheIni.h"

void UMyGameInstance::Init()
{
    Super::Init();
    int32 Mode = 0, Temporal = 0;
    GConfig->GetInt(TEXT("MabaGame"), TEXT("Mode"), Mode, GGameUserSettingsIni);
    GConfig->GetInt(TEXT("MabaGame"), TEXT("Temporal"), Temporal, GGameUserSettingsIni);
    UMabaBlueprintLibrary::SetMabaMode(static_cast<EMabaMode>(FMath::Clamp(Mode, 0, 4)));
    UMabaBlueprintLibrary::SetMabaTemporal(Temporal != 0);
}

void UMyGameInstance::SaveMabaChoice(EMabaMode Mode, bool bTemporal)
{
    GConfig->SetInt(TEXT("MabaGame"), TEXT("Mode"), static_cast<int32>(Mode), GGameUserSettingsIni);
    GConfig->SetInt(TEXT("MabaGame"), TEXT("Temporal"), bTemporal ? 1 : 0, GGameUserSettingsIni);
    GConfig->Flush(false, GGameUserSettingsIni);
    UMabaBlueprintLibrary::SetMabaMode(Mode);
    UMabaBlueprintLibrary::SetMabaTemporal(bTemporal);
}
```

In Blueprint the same flow is: *Event Init* (Game Instance) > read your SaveGame > *Set Maba Mode* /
*Set Maba Temporal*; options screen > save > the same two nodes.

### Starting points by device class (not benchmarks: measure your own game)

| Target | Suggested start |
|---|---|
| Low-end Android phone | Dynamic, Target Fps 30 or 60, Min Scale 0.5, Temporal off (spatial only on mobile) |
| Mid-range phone | Dynamic, Target Fps 60, Min Scale 0.6 |
| Console / handheld PC | Balanced or Quality fixed, Temporal on |
| High-end desktop | Usually leave MABA off (or Ultra Quality) |

### Situations worth handling

| Situation | What to do |
|---|---|
| Split-screen | History is per view; the controller scale is shared by all views. |
| Sequencer cuts | Engine camera cuts reset the history; otherwise call `Reset Maba History`. |
| Custom tonemapper / post chain with the Tonemap pass disabled | MABA hooks the Tonemap pass; if it is disabled the plugin does nothing. |
| Scene capture / reflection / planar reflection views | MABA leaves them alone. |
| Another system sets `r.ScreenPercentage` | Remove it or disable MABA: two writers fight. |
| Heavy post-process materials after the tonemapper | They run at output resolution, after MABA. |

### Build and packaging notes

- It is a **code plugin**: every machine that builds the project needs a C++ toolchain, or you ship a
  prebuilt binary plugin (`BuildPlugin`, section 1).
- Shaders are in the plugin's `Shaders/` folder, mapped at `PostConfigInit`; they are cooked with the
  project like any global shader.
- Only a Win64 Editor build has been compiled. Android and console builds are untested.

## 10. File map

| File | What it is |
|---|---|
| `Source/.../Private/MabaUpscalerModule.cpp` | Module start-up, the `r.Maba.*` console variables, the controller tick, the stats line. |
| `Source/.../Private/MabaViewExtension.cpp/.h` | The scene view extension: jitter, AA override, temporal and upscale passes, history. |
| `Source/.../Private/MabaController.h`, `MabaTemporal.h` | **Copies** of `src/maba_upscaler.h` and `src/maba_temporal.h` (sync with `test/sync_hlsl.ps1`). |
| `Source/.../Public/MabaSettings.h` | The Project Settings page (`UMabaSettings`). |
| `Source/.../Public/MabaBlueprintLibrary.h` | The Blueprint nodes and `FMabaStatus`. |
| `Shaders/MabaUpscale.usf`, `MabaTemporal.usf` | Pixel shaders; `MabaCore.ush` and `MabaTemporalCore.ush` are **copies** of `src/*.hlsl`. |

## 11. FAQ

**Does it replace TSR?** On views it renders it replaces TSR / TAA (it takes the view out of them,
section 1), and gives you its own spatial upscaler plus an optional temporal tier. At 100% scale the
engine's AA is left alone.

**Why is the temporal tier off by default?** It has never run in a game yet (pre-alpha): you should be
the one to turn it on and look at it.

**Does it work in the editor viewport?** The hooks target game views; editor viewport behaviour is
untested. Use Play In Editor.

**Where do I report problems?** Open an issue with the UE version, platform, GPU, and the output of
`r.Maba.ShowStats 1`.
## 12. Licence

Apache-2.0, Copyright 2026 MABA Studios. The quality kernel is derived from AMD FidelityFX Super
Resolution 1.0 (MIT); `NOTICE` and `THIRD_PARTY_NOTICES.md` are included in the plugin folder and must
accompany redistribution. Not affiliated with or endorsed by AMD.
