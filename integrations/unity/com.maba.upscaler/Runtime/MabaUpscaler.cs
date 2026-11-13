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

        [Tooltip("Dynamic holds the target frame rate by moving render scale in 1% steps.")]
        public Mode mode = Mode.Dynamic;
        [Range(0f, 1f)] public float sharpness = 0.5f;
        public float targetFps = 60f;
        [Tooltip("MABA-Upscaler 2 (Temporal): jittered accumulation. Needs depth; costs ~1-3 ms on low-end mobile.")]
        public bool temporal = false;
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
        int texW, texH;              // allocated size of the scene texture (largest rung)
        int rw, rh;                  // this frame's render region
        int lastRw, lastRh;
        int slot;
        bool temporalActive, lastTemporal, projectionOverridden;
        Matrix4x4 plainProj, prevVP;
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

        void OnEnable()
        {
            cam = GetComponent<Camera>();
            ctrl = new MabaController((int)mode, targetFps);
            appliedTargetFps = targetFps;
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
            float maxScale = MabaController.RungScale(MabaController.RungMax);
            int w = Mathf.Max(2, Scaled(sw, maxScale)), h = Mathf.Max(2, Scaled(sh, maxScale));
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
            EnsureTargets(sw, sh);

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

            float scale = ctrl.Scale;
            rw = Mathf.Clamp(Scaled(sw, scale), 2, texW);
            rh = Mathf.Clamp(Scaled(sh, scale), 2, texH);

            // Render into the bottom-left rw x rh texels of the fixed-size texture. pixelRect is
            // relative to the target texture, so the region is exact.
            cam.targetTexture = sceneRT;
            cam.pixelRect = new Rect(0, 0, rw, rh);

            temporalActive = temporal && temporalMat != null && copyMat != null;
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
                MabaTemporal.Frame jf = jitter.BeginFrame();

                // Start from the camera's own projection for this region, then shift it by a
                // sub-texel amount. Unity matrices are [row, column], GL convention.
                cam.ResetProjectionMatrix();
                plainProj = cam.projectionMatrix;
                Matrix4x4 proj = plainProj;
                int col = cam.orthographic ? 3 : 2;   // translation column vs. the z (w = -z) column
                proj[0, col] += 2f * jf.JitterX / rw;
                proj[1, col] += 2f * jf.JitterY / rh;
                cam.projectionMatrix = proj;
                projectionOverridden = true;
            }
            else
            {
                if (projectionOverridden)
                {
                    cam.ResetProjectionMatrix();
                    projectionOverridden = false;
                }
                if (lastTemporal && !temporal)
                {
                    ReleaseTemporalTargets();
                    cam.depthTextureMode = savedDepthMode;   // stop paying for a depth texture
                    RestoreUrpDepth();
                }
                havePrevVP = false;
            }
            lastTemporal = temporalActive;
            lastRw = rw;
            lastRh = rh;
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

        void Upscale()
        {
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

            fpsFrames++;
            double now = Time.unscaledTimeAsDouble;
            if (fpsFrames >= 60 && now > fpsTime)
            {
                fps = (float)(fpsFrames / (now - fpsTime));
                fpsFrames = 0;
                fpsTime = now;
            }
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
                    gather && ctrl.QualityShader ? "quality" : "fast", fps, gpuMs));
        }
    }
}
