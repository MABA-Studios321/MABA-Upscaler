/*==============================================================================================
  MABA Upscaler 2 - quality modes and dynamic controller (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  This header has no graphics-API dependency. It decides, each frame, what resolution to render
  the 3D scene at and which build of maba_upscaler.frag.glsl to upscale it with.

  RUNGS (continuous resolution ladder, lowest to highest)
      rung 0..9    scale 0.50..0.59 in 1% steps, fast shader
      rung 10      scale 0.59, quality shader          "Balanced"
      rung 11..28  scale 0.60..0.77 in 1% steps, quality shader
  The classic presets are anchors on this ladder:
      Performance = rung 0 (0.50, fast), Balanced = rung 10 (0.59, quality),
      Quality = rung 18 (0.67, quality), Ultra Quality = rung 28 (0.77, quality).
  "fast shader" is the default build; "quality shader" is the MABA_QUALITY 1 build. On a device
  without textureGather (OpenGL ES 3.0) use the MABA_GATHER 0 build for every rung.

  MODES
      MABA_MODE_DYNAMIC (default)  moves along the rungs to hold a target frame time.
      MABA_MODE_ULTRA_QUALITY / QUALITY / BALANCED / PERFORMANCE  stay on one anchor rung.

  TIMING
      MabaBeginFrame(u, lastFrameMs, ...)     present-to-present frame time. Simple, but with
                                              vsync on it cannot see GPU headroom: a frame that
                                              finishes early still reports 16.7 ms at 60 Hz.
      MabaBeginFrameGpu(u, gpuMs, ...)        GPU-only time from a timer query (recommended;
                                              EXT_disjoint_timer_query on GLES, vkCmdWriteTimestamp
                                              on Vulkan). Steps up whenever the GPU is comfortably
                                              under budget, even at the vsync cap. Some drivers
                                              latch timestamps once per frame (begin == end); such
                                              a timer cannot measure GPU time - detect it and fall
                                              back to a glFinish-timed probe frame.

  USAGE
      MabaUpscaler maba;
      MabaInit(&maba, MABA_MODE_DYNAMIC, 60.0f);

      // Allocate the scene render target ONCE at the largest size:
      int texW, texH;
      MabaMaxRenderSize(outW, outH, &texW, &texH);

      // Every frame:
      MabaFrame f = MabaBeginFrameGpu(&maba, lastGpuMs, outW, outH);
      //   render the scene into viewport (0, 0, f.renderWidth, f.renderHeight) of that target
      //   bind the program for f.qualityShader (0 = fast build, 1 = MABA_QUALITY build)
      float size[4], params[4];
      MabaUniforms(&f, texW, texH, 0.5f, size, params);
      //   set uMabaInputSize = size, uMabaParams = params, draw 3 vertices, then draw the UI

  Thermal / battery: call MabaSetTargetFps(&maba, 30.0f) when the device throttles; the
  controller keeps its rung and re-settles against the new budget.
==============================================================================================*/
#ifndef MABA_UPSCALER_H
#define MABA_UPSCALER_H

#ifdef __cplusplus
extern "C" {
#endif

#define MABA_RUNG_COUNT 29
#define MABA_RUNG_MIN 0
#define MABA_RUNG_MAX (MABA_RUNG_COUNT - 1)

typedef enum MabaMode
{
    MABA_MODE_DYNAMIC = 0,
    MABA_MODE_ULTRA_QUALITY,
    MABA_MODE_QUALITY,
    MABA_MODE_BALANCED,
    MABA_MODE_PERFORMANCE
} MabaMode;

/* Rung -> render scale and shader build. */
static inline float MabaRungScale(int rung)
{
    return (float)((rung <= 9) ? (50 + rung) : (49 + rung)) * 0.01f;
}

static inline int MabaRungQuality(int rung)
{
    return rung >= 10;
}

typedef struct MabaUpscaler
{
    MabaMode mode;
    float targetMs;     /* frame time to hold in Dynamic mode */
    int   rung;         /* current position on the ladder */
    float avgMs;        /* smoothed frame time */
    int   overFrames;   /* consecutive frames over budget */
    int   goodFrames;   /* consecutive frames within budget */
    int   upWait;       /* good frames required before trying a higher rung */
    int   probing;      /* 1 while a recent step up is still being proven */
} MabaUpscaler;

typedef struct MabaFrame
{
    int   rung;
    int   renderWidth;
    int   renderHeight;
    int   qualityShader;
    float scale;
} MabaFrame;

/* Tuning of the dynamic controller. */
#define MABA_DYN_START_RUNG    10     /* Balanced */
#define MABA_DYN_OVER_RATIO    1.02f  /* smoothed frame time above target * this = over budget */
#define MABA_DYN_DOWN_FRAMES   20     /* over-budget frames before stepping down */
#define MABA_DYN_UP_FRAMES     180    /* good frames before the first attempt to step up */
#define MABA_DYN_UP_FRAMES_MAX 3600   /* cap on the back-off after failed attempts */
#define MABA_DYN_PROVEN_FRAMES 300    /* good frames after a step up that halve the back-off */

static inline int MabaModeRung(MabaMode mode)
{
    switch (mode)
    {
        case MABA_MODE_ULTRA_QUALITY: return 28;
        case MABA_MODE_QUALITY:       return 18;
        case MABA_MODE_BALANCED:      return 10;
        case MABA_MODE_PERFORMANCE:   return 0;
        case MABA_MODE_DYNAMIC:       return MABA_DYN_START_RUNG;
        default:                      return MABA_DYN_START_RUNG;
    }
}

static inline void MabaSetMode(MabaUpscaler* u, MabaMode mode)
{
    u->mode = mode;
    u->rung = MabaModeRung(mode);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->upWait = MABA_DYN_UP_FRAMES;
    u->probing = 0;
}

static inline void MabaInit(MabaUpscaler* u, MabaMode mode, float targetFps)
{
    u->targetMs = 1000.0f / (targetFps > 1.0f ? targetFps : 60.0f);
    MabaSetMode(u, mode);
}

/* Change the frame-rate budget at runtime (thermal throttling, battery saver, user setting).
   Keeps the current rung; the controller re-settles against the new budget. */
static inline void MabaSetTargetFps(MabaUpscaler* u, float targetFps)
{
    u->targetMs = 1000.0f / (targetFps > 1.0f ? targetFps : 60.0f);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->probing = 0;
}

/* Seed the ladder from a startup calibration instead of always starting at Balanced. */
static inline void MabaSeedRung(MabaUpscaler* u, int rung)
{
    if (rung < MABA_RUNG_MIN) rung = MABA_RUNG_MIN;
    if (rung > MABA_RUNG_MAX) rung = MABA_RUNG_MAX;
    u->rung = rung;
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->probing = 0;
}

/* Size to allocate the scene render target at, so every rung fits without reallocation. */
static inline void MabaMaxRenderSize(int outW, int outH, int* texW, int* texH)
{
    float s = MabaRungScale(MABA_RUNG_MAX);
    *texW = (int)((float)outW * s + 0.5f);
    *texH = (int)((float)outH * s + 0.5f);
}

/* Dynamic mode: step down quickly when frames run over budget, step up cautiously, and back off
   exponentially when a step up does not hold, so the game does not oscillate. */
static inline void MabaUpdateDynamic(MabaUpscaler* u, float frameMs)
{
    int over;
    if (frameMs <= 0.0f || frameMs > 1000.0f) return;   /* ignore pauses and loading hitches */
    u->avgMs = (u->avgMs <= 0.0f) ? frameMs : u->avgMs + (frameMs - u->avgMs) * 0.1f;
    over = u->avgMs > u->targetMs * MABA_DYN_OVER_RATIO;

    if (over)
    {
        u->goodFrames = 0;
        if (++u->overFrames >= MABA_DYN_DOWN_FRAMES && u->rung > MABA_RUNG_MIN)
        {
            u->rung--;
            u->overFrames = 0;
            u->avgMs = u->targetMs;
            if (u->probing)
            {
                u->upWait *= 2;
                if (u->upWait > MABA_DYN_UP_FRAMES_MAX) u->upWait = MABA_DYN_UP_FRAMES_MAX;
                u->probing = 0;
            }
        }
    }
    else
    {
        u->overFrames = 0;
        u->goodFrames++;
        if (u->probing && u->goodFrames >= MABA_DYN_PROVEN_FRAMES)
        {
            u->probing = 0;
            u->upWait /= 2;   /* relax the back-off gradually, not all at once */
            if (u->upWait < MABA_DYN_UP_FRAMES) u->upWait = MABA_DYN_UP_FRAMES;
        }
        if (!u->probing && u->goodFrames >= u->upWait && u->rung < MABA_RUNG_MAX)
        {
            u->rung++;
            u->goodFrames = 0;
            u->probing = 1;
        }
    }
}

static inline MabaFrame MabaMakeFrame(const MabaUpscaler* u, int outW, int outH)
{
    MabaFrame f;
    f.rung = u->rung;
    f.scale = MabaRungScale(u->rung);
    f.qualityShader = MabaRungQuality(u->rung);
    f.renderWidth = (int)((float)outW * f.scale + 0.5f);
    f.renderHeight = (int)((float)outH * f.scale + 0.5f);
    if (f.renderWidth < 2) f.renderWidth = 2;
    if (f.renderHeight < 2) f.renderHeight = 2;
    return f;
}

/* Call once per frame with the previous present-to-present frame time. */
static inline MabaFrame MabaBeginFrame(MabaUpscaler* u, float lastFrameMs, int outW, int outH)
{
    if (u->mode == MABA_MODE_DYNAMIC) MabaUpdateDynamic(u, lastFrameMs);
    return MabaMakeFrame(u, outW, outH);
}

/* Call once per frame with the previous frame's GPU-only time (timer query). Preferred: it sees
   headroom even when vsync caps the present-to-present time. */
static inline MabaFrame MabaBeginFrameGpu(MabaUpscaler* u, float gpuMs, int outW, int outH)
{
    if (u->mode == MABA_MODE_DYNAMIC) MabaUpdateDynamic(u, gpuMs);
    return MabaMakeFrame(u, outW, outH);
}

/* Values for the shader's uMabaInputSize and uMabaParams. texW/texH is the allocated size of the
   scene render target; sharpness is 0..1. */
static inline void MabaUniforms(const MabaFrame* f, int texW, int texH, float sharpness,
                                float inputSize[4], float params[4])
{
    inputSize[0] = (float)f->renderWidth;
    inputSize[1] = (float)f->renderHeight;
    inputSize[2] = 1.0f / (float)texW;
    inputSize[3] = 1.0f / (float)texH;
    params[0] = sharpness;
    params[1] = params[2] = params[3] = 0.0f;
}

#ifdef __cplusplus
}
#endif
#endif /* MABA_UPSCALER_H */
