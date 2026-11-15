// MABA Upscaler - camera component. Renders the camera into a sub-region of a fixed-size
// render texture (no reallocation on scale changes) and upscales that region to the screen
// after the camera has finished, before screen-space overlay UI. Optional MABA-Upscaler 2
// (Temporal) resolve tier.
//
// Works with URP and the built-in pipeline: the camera renders normally into targetTexture
// (post-processing/tonemapping included), so the upscaler input is finished LDR color.
// Built-in calls OnPostRender; scriptable pipelines call RenderPipelineManager.endCameraRendering.
//
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System;
using UnityEngine;
using UnityEngine.Rendering;
#if MABA_URP
using UnityEngine.Rendering.Universal;
#endif

namespace Maba
{
    [RequireComponent(typeof(Camera))]
    [DisallowMultipleComponent]
    [AddComponentMenu("MABA/MABA Upscaler")]
    public sealed class MabaUpscaler : MonoBehaviour
    {
        // Order matches MabaController.Mode* and the C header's MabaMode.
        public enum Mode { Dynamic, UltraQuality, Quality, Balanced, Performance }

        [Header("Upscaler")]
        [Tooltip("Dynamic holds the target frame rate by moving render scale in 1% steps. The others are fixed render scales: Ultra Quality 0.77, Quality 0.67, Balanced 0.59, Performance 0.50.")]
        public Mode mode = Mode.Dynamic;
        [Tooltip("Sharpening strength. 0.5 is the measured sweet spot.")]
        [Range(0f, 1f)] public float sharpness = 0.5f;
        [Header("Dynamic mode")]
        [Tooltip("The frame rate Dynamic mode holds.")]
        public float targetFps = 60f;
        [Tooltip("Dynamic mode never renders below this fraction of the screen resolution (0.35..1). The fixed presets ignore the range.")]
        [Range(0.35f, 1f)] public float minScale = 0.35f;
        [Tooltip("Dynamic mode never renders above this fraction of the screen resolution (0.35..1; 1 = native, no upscale pass). A lower ceiling also allocates a smaller render texture.")]
        [Range(0.35f, 1f)] public float maxScale = 1f;
        [Tooltip("MABA-Upscaler 2 (Temporal): jittered accumulation. Needs depth; costs ~1-3 ms on a low-end phone.")]
        public bool temporal = false;
        [Header("Temporal tuning (only used when Temporal is on)")]
        [Tooltip("How much of the previous frame is kept, 0.80 - 0.95. Higher is steadier and ghosts more.")]
        [Range(0.5f, 0.98f)] public float historyWeight = 0.9f;
        [Tooltip("Width of the colour clamp that rejects ghosts, 1.0 - 1.5. Lower rejects ghosts harder.")]
        [Range(0.5f, 3f)] public float clipGamma = 1.25f;
        [Tooltip("Depth difference that rejects history (disocclusion), 0.005 - 0.02.")]
        [Range(0.001f, 0.1f)] public float depthTolerance = 0.01f;
        [Header("Debug")]
        [Tooltip("Show a one-line diagnostic overlay (development only).")]
        public bool debugOverlay = false;

        static readonly int InputId = Shader.PropertyToID("_MabaInput");
        static readonly int InputSizeId = Shader.PropertyToID("_MabaInputSize");
        static readonly int ParamsId = Shader.PropertyToID("_MabaParams");
        static readonly int HistoryId = Shader.PropertyToID("_History");
        static readonly int DepthId = Shader.PropertyToID("_Depth");
        static readonly int PrevDepthId = Shader.PropertyToID("_PrevDepth");
        static readonly int InvVPId = Shader.PropertyToID("_InvVP");
        static readonly int PrevVPId = Shader.PropertyToID("_PrevVP");
        static readonly int TParamsId = Shader.PropertyToID("_TParams");
        static readonly int TexelId = Shader.PropertyToID("_Texel");
        static readonly int RegionId = Shader.PropertyToID("_Region");
        static readonly int JitterId = Shader.PropertyToID("_Jitter");
        static readonly int ReversedZId = Shader.PropertyToID("_MabaReversedZ");

        Camera cam;
        MabaController ctrl;
        MabaTemporal jitter;
        RenderTexture sceneRT;
        readonly RenderTexture[] resolveRT = new RenderTexture[2];
        readonly RenderTexture[] depthRT = new RenderTexture[2];
        Material upscaleMat, temporalMat, copyMat;
        bool gather;                 // false on ES 3.0-class hardware: single gather-free pass
        Rect savedRect;
        DepthTextureMode savedDepthMode;
#if MABA_URP
        bool savedRequiresDepth, haveSavedRequiresDepth;
#endif
        float appliedTargetFps;
        float appliedMinScale = -1f, appliedMaxScale = -1f;
        int texW, texH;              // allocated size of the scene texture (largest rung)
        int rw, rh;                  // this frame's render region
        int lastRw, lastRh;
        int slot;
        bool temporalActive, lastTemporal, projectionOverridden;
        bool nativeFrame;            // scale 1.00 without temporal: the camera renders straight to the screen
        Matrix4x4 plainProj, prevVP;
        Vector2 jitterTexels;        // this frame's jitter, for the resolve pass
        bool havePrevVP;
        readonly FrameTiming[] timings = new FrameTiming[1];
        float gpuMs;
        float fps;
        int fpsFrames;
        double fpsTime;

        static Material NewMaterial(string resource, string shaderName)
        {
            // The shaders live in a Resources folder so player builds include them; Shader.Find
            // alone returns null in a build for a shader nothing else references.
            Shader s = Resources.Load<Shader>(resource);
            if (s == null) s = Shader.Find(shaderName);
            if (s == null || !s.isSupported) return null;
            return new Material(s) { hideFlags = HideFlags.HideAndDontSave };
        }

        // ---- Read-only status (for UI, the inspector and your own code) ----------------------------

        /// <summary>Raised when the render scale changes (Dynamic mode stepping, or a mode change).</summary>
        public event Action<float> ScaleChanged;
        float lastScale = -1f;

        /// <summary>Current render scale, 0.35 .. 1.00 (1.00 = native: nothing is upscaled).</summary>
        public float RenderScale { get { return ctrl != null ? ctrl.Scale : 1f; } }
        /// <summary>Position on the 1% ladder, -15 .. 51.</summary>
        public int Rung { get { return ctrl != null ? ctrl.Rung : 0; } }
        /// <summary>This frame's render region in pixels.</summary>
        public Vector2Int RenderSize { get { return new Vector2Int(rw, rh); } }
        /// <summary>True while the camera renders straight to the screen (scale 1.00, no temporal).</summary>
        public bool IsNative { get { return nativeFrame; } }
        /// <summary>True when the 12-tap quality kernel is in use (false: the fast kernel).</summary>
        public bool QualityKernel { get { return gather && ctrl != null && ctrl.QualityShader && !nativeFrame; } }
        /// <summary>True when the temporal resolve ran this frame.</summary>
        public bool TemporalRunning { get { return temporalActive && resolveRT[0] != null && !nativeFrame; } }
        /// <summary>Smoothed frames per second (as measured by the component).</summary>
        public float CurrentFps { get { return fps; } }
        /// <summary>GPU time of the last frame in ms where the platform reports it, else 0.</summary>
        public float GpuMs { get { return gpuMs; } }

        /// <summary>Choose Dynamic or one of the fixed presets.</summary>
        public void SetMode(Mode newMode) { mode = newMode; }

        void OnValidate()
        {
            if (maxScale < minScale) maxScale = minScale;
            targetFps = Mathf.Clamp(targetFps, 15f, 240f);
        }

        void OnEnable()
        {
            cam = GetComponent<Camera>();
            ctrl = new MabaController((int)mode, targetFps);
            appliedTargetFps = targetFps;
            ctrl.SetScaleRange(minScale, maxScale);
            appliedMinScale = minScale;
            appliedMaxScale = maxScale;
            nativeFrame = false;
            jitter = new MabaTemporal();

            // textureGather needs ES 3.1 / SM 4.5 class hardware; below that use the gather-free
            // fast shader for every rung (same rule as the GLSL reference).
            gather = SystemInfo.graphicsShaderLevel >= 45;
            upscaleMat = gather ? NewMaterial("MabaShaders/MabaUpscaler", "MABA/Upscaler") : null;
            if (upscaleMat == null)
            {
                gather = false;
                upscaleMat = NewMaterial("MabaShaders/MabaUpscalerCompat", "MABA/UpscalerCompat");
            }
            temporalMat = NewMaterial("MabaShaders/MabaTemporal", "MABA/Temporal");
            copyMat = NewMaterial("MabaShaders/MabaDepthCopy", "MABA/DepthCopy");
            if (upscaleMat == null)
            {
                Debug.LogError("MABA Upscaler: upscale shader missing or unsupported on this device; component disabled.", this);
                enabled = false;
                return;
            }

            savedRect = cam.rect;
            savedDepthMode = cam.depthTextureMode;
            fpsTime = Time.unscaledTimeAsDouble;
            fpsFrames = 0;
            lastTemporal = false;
            havePrevVP = false;
            RenderPipelineManager.endCameraRendering += OnEndCameraRendering;
        }

        void OnDisable()
        {
            RenderPipelineManager.endCameraRendering -= OnEndCameraRendering;
            if (cam != null && sceneRT != null)
            {
                if (cam.targetTexture == sceneRT) cam.targetTexture = null;
                cam.rect = savedRect;
                cam.depthTextureMode = savedDepthMode;
                if (projectionOverridden) cam.ResetProjectionMatrix();
            }
            RestoreUrpDepth();
            projectionOverridden = false;
            ReleaseTargets();
            DestroyMaterial(ref upscaleMat);
            DestroyMaterial(ref temporalMat);
            DestroyMaterial(ref copyMat);
        }

        // URP: remember and restore the camera's own "Depth Texture" setting.
        void RequestUrpDepth()
        {
#if MABA_URP
            if (!(GraphicsSettings.currentRenderPipeline is UniversalRenderPipelineAsset)) return;
            var data = cam.GetUniversalAdditionalCameraData();
            if (!haveSavedRequiresDepth)
            {
                savedRequiresDepth = data.requiresDepthTexture;
                haveSavedRequiresDepth = true;
            }
            data.requiresDepthTexture = true;
#endif
        }

        void RestoreUrpDepth()
        {
#if MABA_URP
            if (!haveSavedRequiresDepth || cam == null) return;
            var data = cam.GetComponent<UniversalAdditionalCameraData>();
            if (data != null) data.requiresDepthTexture = savedRequiresDepth;
            haveSavedRequiresDepth = false;
#endif
        }

        static void DestroyMaterial(ref Material m)
        {
            if (m != null) Destroy(m);
            m = null;
        }

        static void ReleaseRT(ref RenderTexture rt)
        {
            if (rt == null) return;
            rt.Release();
            Destroy(rt);
            rt = null;
        }

        void ReleaseTemporalTargets()
        {
            for (int i = 0; i < 2; i++)
            {
                ReleaseRT(ref resolveRT[i]);
                ReleaseRT(ref depthRT[i]);
            }
        }

        void ReleaseTargets()
        {
            ReleaseRT(ref sceneRT);
            ReleaseTemporalTargets();
        }

        // Same rounding as the C header: (int)(x * scale + 0.5).
        static int Scaled(int size, float scale) { return (int)(size * scale + 0.5f); }

        void EnsureTargets(int sw, int sh)
        {
            // Sized for the largest rung the controller can ask for: the top of the Dynamic range,
            // or a fixed preset's own rung when that is higher (presets ignore the range). It used
            // to be the classic 0.77 ceiling, which would have silently clamped the render region
            // once Dynamic mode may climb to native. Changing maxScale or the mode at run time
            // reallocates the textures. They are only created once a frame actually needs them
            // (see LateUpdate), so a game that stays at native never pays for them.
            float topScale = MabaController.RungScale(Mathf.Max(ctrl.RungHi, ctrl.Rung));
            int w = Mathf.Max(2, Scaled(sw, topScale)), h = Mathf.Max(2, Scaled(sh, topScale));
            if (sceneRT != null && texW == w && texH == h) return;
            if (cam.targetTexture == sceneRT) cam.targetTexture = null;
            ReleaseTargets();
            texW = w; texH = h;
            sceneRT = new RenderTexture(w, h, 24, RenderTextureFormat.ARGB32);
            sceneRT.name = "MABA Scene";
            sceneRT.filterMode = FilterMode.Bilinear;
            sceneRT.wrapMode = TextureWrapMode.Clamp;
            sceneRT.useMipMap = false;
            sceneRT.Create();
            jitter.Reset();
            havePrevVP = false;
        }

        void EnsureTemporalTargets()
        {
            if (resolveRT[0] != null) return;
            RenderTextureFormat depthFormat =
                SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.RFloat) ? RenderTextureFormat.RFloat
                : RenderTextureFormat.RHalf;
            for (int i = 0; i < 2; i++)
            {
                resolveRT[i] = new RenderTexture(texW, texH, 0, RenderTextureFormat.ARGB32);
                resolveRT[i].name = "MABA Resolve " + i;
                resolveRT[i].filterMode = FilterMode.Bilinear;
                resolveRT[i].wrapMode = TextureWrapMode.Clamp;
                resolveRT[i].Create();
                // Depth is stored as data, never colour-converted.
                depthRT[i] = new RenderTexture(texW, texH, 0, depthFormat, RenderTextureReadWrite.Linear);
                depthRT[i].name = "MABA Depth " + i;
                depthRT[i].filterMode = FilterMode.Point;
                depthRT[i].wrapMode = TextureWrapMode.Clamp;
                depthRT[i].Create();
            }
            jitter.Reset();
            havePrevVP = false;
        }

        void LateUpdate()
        {
            int sw = Screen.width, sh = Screen.height;
            if (sw < 4 || sh < 4 || upscaleMat == null) return;

            // SetScaleRange resets the controller's counters, so apply it only when it changed.
            if (minScale != appliedMinScale || maxScale != appliedMaxScale)
            {
                ctrl.SetScaleRange(minScale, maxScale);
                appliedMinScale = minScale;
                appliedMaxScale = maxScale;
            }

            // GPU-only time where the platform reports it, present-to-present otherwise.
            float ms = Time.unscaledDeltaTime * 1000f;
            gpuMs = 0f;
            FrameTimingManager.CaptureFrameTimings();
            if (FrameTimingManager.GetLatestFrameTimings(1, timings) > 0 && timings[0].gpuFrameTime > 0.0)
            {
                gpuMs = (float)timings[0].gpuFrameTime;
                ms = gpuMs;
            }

            // SetTargetFps and SetMode reset the controller's counters, so only call them when
            // the setting actually changed; calling them every frame would freeze Dynamic mode.
            if (targetFps != appliedTargetFps)
            {
                ctrl.SetTargetFps(targetFps);
                appliedTargetFps = targetFps;
            }
            if (ctrl.Mode != (int)mode) ctrl.SetMode((int)mode);
            ctrl.BeginFrame(ms);
            if (ctrl.Scale != lastScale)
            {
                lastScale = ctrl.Scale;
                if (ScaleChanged != null) ScaleChanged(lastScale);
            }

            temporalActive = temporal && temporalMat != null && copyMat != null;

            // Native resolution (scale 1.00) without the temporal tier has nothing to upscale: the
            // camera renders straight to the screen and the upscale pass is skipped.
            nativeFrame = ctrl.IsNative && !temporalActive;
            if (nativeFrame)
            {
                if (cam.targetTexture == sceneRT) cam.targetTexture = null;
                cam.rect = savedRect;
                StopTemporal();
                lastTemporal = false;
                rw = lastRw = sw;
                rh = lastRh = sh;
                return;
            }

            // The scene texture follows the (possibly just changed) mode and range, so size it
            // after the controller has moved.
            EnsureTargets(sw, sh);
            float scale = ctrl.Scale;
            rw = Mathf.Clamp(Scaled(sw, scale), 2, texW);
            rh = Mathf.Clamp(Scaled(sh, scale), 2, texH);

            // Render into the bottom-left rw x rh texels of the fixed-size texture. pixelRect is
            // relative to the target texture, so the region is exact.
            cam.targetTexture = sceneRT;
            cam.pixelRect = new Rect(0, 0, rw, rh);

            if (temporalActive)
            {
                EnsureTemporalTargets();
                cam.depthTextureMode |= DepthTextureMode.Depth;
                RequestUrpDepth();
                if (rw != lastRw || rh != lastRh || !lastTemporal)
                {
                    jitter.Reset();
                    havePrevVP = false;
                }
                jitter.HistoryWeight = historyWeight;
                jitter.ClipGamma = clipGamma;
                jitter.DepthTolerance = depthTolerance;
                MabaTemporal.Frame jf = jitter.BeginFrame();

                // Start from the camera's own projection for this region, then shift it by a
                // sub-texel amount. Unity matrices are [row, column], GL convention.
                cam.ResetProjectionMatrix();
                plainProj = cam.projectionMatrix;
                Matrix4x4 proj = plainProj;
                // The content must move BY +jitter texels. For a perspective projection (clip.w = -z)
                // adding d to column 2 shifts NDC by -d, so SUBTRACT; an orthographic projection
                // is shifted through its translation column and ADDS.
                if (cam.orthographic)
                {
                    proj[0, 3] += 2f * jf.JitterX / rw;
                    proj[1, 3] += 2f * jf.JitterY / rh;
                }
                else
                {
                    proj[0, 2] -= 2f * jf.JitterX / rw;
                    proj[1, 2] -= 2f * jf.JitterY / rh;
                }
                jitterTexels = new Vector2(jf.JitterX, jf.JitterY);
                cam.projectionMatrix = proj;
                projectionOverridden = true;
            }
            else
            {
                StopTemporal();
            }
            lastTemporal = temporalActive;
            lastRw = rw;
            lastRh = rh;
        }

        // The temporal tier is off for this frame: undo its projection jitter, and release its
        // textures and depth request the first time it stops.
        void StopTemporal()
        {
            if (projectionOverridden)
            {
                cam.ResetProjectionMatrix();
                projectionOverridden = false;
            }
            if (lastTemporal)
            {
                ReleaseTemporalTargets();
                cam.depthTextureMode = savedDepthMode;   // stop paying for a depth texture
                RestoreUrpDepth();
            }
            havePrevVP = false;
        }

        // Built-in render pipeline.
        void OnPostRender()
        {
            if (GraphicsSettings.currentRenderPipeline == null) Upscale();
        }

        // URP / other scriptable pipelines (they do not send OnPostRender).
        void OnEndCameraRendering(ScriptableRenderContext context, Camera camera)
        {
            if (camera == cam) Upscale();
        }

        static void DrawFullscreen(Material mat, int pass, RenderTexture target, int w, int h)
        {
            Graphics.SetRenderTarget(target);
            GL.Viewport(new Rect(0, 0, w, h));
            mat.SetPass(pass);
            Graphics.DrawProceduralNow(MeshTopology.Triangles, 3);
        }

        void CountFrame()
        {
            fpsFrames++;
            double now = Time.unscaledTimeAsDouble;
            if (fpsFrames >= 60 && now > fpsTime)
            {
                fps = (float)(fpsFrames / (now - fpsTime));
                fpsFrames = 0;
                fpsTime = now;
            }
        }

        void Upscale()
        {
            if (nativeFrame)
            {
                CountFrame();   // rendered straight to the screen: no upscale pass
                return;
            }
            if (sceneRT == null || upscaleMat == null || rw < 2 || rh < 2) return;
            if (cam.targetTexture != sceneRT) return;   // LateUpdate has not run for this frame

            Texture src = sceneRT;
            if (temporalActive && resolveRT[0] != null)
            {
                int prev = 1 - slot;
                Matrix4x4 vp = plainProj * cam.worldToCameraMatrix;   // unjittered, GL convention

                // 1. This frame's depth, converted to GL window depth (0 near .. 1 far) and
                //    packed into the region. It doubles as next frame's previous depth. The shader
                //    reads the pipeline's global _CameraDepthTexture directly: URP binds it from a
                //    command buffer, where Shader.GetGlobalTexture cannot see it.
                copyMat.SetVector(RegionId, new Vector4(rw, rh, 0, 0));
                copyMat.SetFloat(ReversedZId, SystemInfo.usesReversedZBuffer ? 1f : 0f);
                DrawFullscreen(copyMat, 0, depthRT[slot], rw, rh);

                // 2. Temporal resolve at render resolution.
                temporalMat.SetTexture(InputId, sceneRT);
                temporalMat.SetTexture(HistoryId, resolveRT[prev]);
                temporalMat.SetTexture(DepthId, depthRT[slot]);
                temporalMat.SetTexture(PrevDepthId, depthRT[prev]);
                temporalMat.SetMatrix(InvVPId, vp.inverse);
                temporalMat.SetMatrix(PrevVPId, havePrevVP ? prevVP : vp);
                temporalMat.SetVector(TParamsId, new Vector4(jitter.HistoryWeight,
                    jitter.DepthTolerance, havePrevVP ? 0f : 1f, jitter.ClipGamma));
                temporalMat.SetVector(TexelId, new Vector4(1f / texW, 1f / texH, 0, 0));
                temporalMat.SetVector(RegionId, new Vector4(rw, rh, 0, 0));
                temporalMat.SetVector(JitterId, new Vector4(jitterTexels.x, jitterTexels.y, 0, 0));
                DrawFullscreen(temporalMat, 0, resolveRT[slot], rw, rh);

                prevVP = vp;
                havePrevVP = true;
                src = resolveRT[slot];
                slot = prev;
            }
            else
            {
                havePrevVP = false;   // temporal off: restart accumulation when it returns
            }

            // 3. Upscale the region to the screen.
            upscaleMat.SetTexture(InputId, src);
            upscaleMat.SetVector(InputSizeId, new Vector4(rw, rh, 1f / texW, 1f / texH));
            upscaleMat.SetVector(ParamsId, new Vector4(sharpness, 0, 0, 0));
            DrawFullscreen(upscaleMat, gather && ctrl.QualityShader ? 1 : 0, null, Screen.width, Screen.height);
            CountFrame();
        }

        /// <summary>Call on camera cuts / teleports so the temporal tier drops its history.</summary>
        public void ResetHistory()
        {
            if (jitter != null) jitter.Reset();
            havePrevVP = false;
        }

        void OnGUI()
        {
            if (!debugOverlay || ctrl == null) return;
            GUI.Label(new Rect(8, 8, 700, 24),
                string.Format("MABA {0}{1} | scale {2:0.00} {3} | {4:0} fps | gpu {5:0.0} ms",
                    mode, temporalActive ? " +temporal" : "", ctrl.Scale,
                    nativeFrame ? "native" : (gather && ctrl.QualityShader ? "quality" : "fast"), fps, gpuMs));
        }
    }
}
