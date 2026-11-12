/*==============================================================================================
  MABA Upscaler 1.4 - quality modes and dynamic controller (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  This header has no graphics-API dependency. It decides, each frame, what resolution to render
  the 3D scene at and which build of maba_upscaler.frag.glsl to upscale it with.

  QUALITY LEVELS (lowest to highest)
      level 0   0.50 scale, fast shader       "Performance"
      level 1   0.59 scale, fast shader       (used by Dynamic only)
      level 2   0.59 scale, quality shader    "Balanced"
      level 3   0.67 scale, quality shader    "Quality"
      level 4   0.77 scale, quality shader    "Ultra Quality"
  "fast shader" is the default build; "quality shader" is the MABA_QUALITY 1 build. On a device
  without textureGather (OpenGL ES 3.0) use the MABA_GATHER 0 build for every level.

  MODES
      MABA_MODE_DYNAMIC (default)  moves between the levels to hold a target frame time.
      MABA_MODE_ULTRA_QUALITY / QUALITY / BALANCED / PERFORMANCE  stay on one level.

  USAGE
      MabaUpscaler maba;
      MabaInit(&maba, MABA_MODE_DYNAMIC, 60.0f);

      // Allocate the scene render target ONCE at the largest size:
      int texW, texH;
      MabaMaxRenderSize(outW, outH, &texW, &texH);

      // Every frame:
      MabaFrame f = MabaBeginFrame(&maba, lastFrameMs, outW, outH);
      //   render the scene into viewport (0, 0, f.renderWidth, f.renderHeight) of that target
      //   bind the program for f.qualityShader (0 = fast build, 1 = MABA_QUALITY build)
      float size[4], params[4];
      MabaUniforms(&f, texW, texH, 0.5f, size, params);
      //   set uMabaInputSize = size, uMabaParams = params, draw 3 vertices, then draw the UI

  lastFrameMs is the time the previous frame took, in milliseconds (present to present).
==============================================================================================*/
#ifndef MABA_UPSCALER_H
#define MABA_UPSCALER_H

#ifdef __cplusplus
extern "C" {
#endif

#define MABA_LEVEL_COUNT 5

typedef enum MabaMode
{
    MABA_MODE_DYNAMIC = 0,
    MABA_MODE_ULTRA_QUALITY,
    MABA_MODE_QUALITY,
    MABA_MODE_BALANCED,
    MABA_MODE_PERFORMANCE
} MabaMode;

typedef struct MabaLevel
{
    float scale;          /* render size / output size, per axis */
    int   qualityShader;  /* 0 = default build, 1 = MABA_QUALITY build */
} MabaLevel;

static const MabaLevel kMabaLevels[MABA_LEVEL_COUNT] =
{
    { 0.50f, 0 },
    { 0.59f, 0 },
    { 0.59f, 1 },
    { 0.67f, 1 },
    { 0.77f, 1 }
};

typedef struct MabaUpscaler
{
    MabaMode mode;
    float targetMs;     /* frame time to hold in Dynamic mode */
    int   level;        /* current index into kMabaLevels */
    float avgMs;        /* smoothed frame time */
    int   overFrames;   /* consecutive frames over budget */
    int   goodFrames;   /* consecutive frames within budget */
    int   upWait;       /* good frames required before trying a higher level */
    int   probing;      /* 1 while a recent step up is still being proven */
} MabaUpscaler;

typedef struct MabaFrame
{
    int   level;
    int   renderWidth;
    int   renderHeight;
    int   qualityShader;
    float scale;
} MabaFrame;

/* Tuning of the dynamic controller. */
#define MABA_DYN_START_LEVEL   2      /* Balanced */
#define MABA_DYN_OVER_RATIO    1.02f  /* smoothed frame time above target * this = over budget */
#define MABA_DYN_DOWN_FRAMES   20     /* over-budget frames before stepping down */
#define MABA_DYN_UP_FRAMES     180    /* good frames before the first attempt to step up */
#define MABA_DYN_UP_FRAMES_MAX 3600   /* cap on the back-off after failed attempts */
#define MABA_DYN_PROVEN_FRAMES 300    /* good frames after a step up that halve the back-off */

static int MabaModeLevel(MabaMode mode)
{
    switch (mode)
    {
        case MABA_MODE_ULTRA_QUALITY: return 4;
        case MABA_MODE_QUALITY:       return 3;
        case MABA_MODE_BALANCED:      return 2;
        case MABA_MODE_PERFORMANCE:   return 0;
        default:                      return MABA_DYN_START_LEVEL;
    }
}

static void MabaSetMode(MabaUpscaler* u, MabaMode mode)
{
    u->mode = mode;
    u->level = MabaModeLevel(mode);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->upWait = MABA_DYN_UP_FRAMES;
    u->probing = 0;
}

static void MabaInit(MabaUpscaler* u, MabaMode mode, float targetFps)
{
    u->targetMs = 1000.0f / (targetFps > 1.0f ? targetFps : 60.0f);
    MabaSetMode(u, mode);
}

/* Size to allocate the scene render target at, so every level fits without reallocation. */
static void MabaMaxRenderSize(int outW, int outH, int* texW, int* texH)
{
    float s = kMabaLevels[MABA_LEVEL_COUNT - 1].scale;
    *texW = (int)((float)outW * s + 0.5f);
    *texH = (int)((float)outH * s + 0.5f);
}

/* Dynamic mode: step down quickly when frames run over budget, step up cautiously, and back off
   exponentially when a step up does not hold, so the game does not oscillate. */
static void MabaUpdateDynamic(MabaUpscaler* u, float frameMs)
{
    int over;
    if (frameMs <= 0.0f || frameMs > 1000.0f) return;   /* ignore pauses and loading hitches */
    u->avgMs = (u->avgMs <= 0.0f) ? frameMs : u->avgMs + (frameMs - u->avgMs) * 0.1f;
    over = u->avgMs > u->targetMs * MABA_DYN_OVER_RATIO;

    if (over)
    {
        u->goodFrames = 0;
        if (++u->overFrames >= MABA_DYN_DOWN_FRAMES && u->level > 0)
        {
            u->level--;
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
        if (!u->probing && u->goodFrames >= u->upWait && u->level < MABA_LEVEL_COUNT - 1)
        {
            u->level++;
            u->goodFrames = 0;
            u->probing = 1;
        }
    }
}

/* Call once per frame, before rendering the scene. */
static MabaFrame MabaBeginFrame(MabaUpscaler* u, float lastFrameMs, int outW, int outH)
{
    MabaFrame f;
    if (u->mode == MABA_MODE_DYNAMIC) MabaUpdateDynamic(u, lastFrameMs);
    f.level = u->level;
    f.scale = kMabaLevels[u->level].scale;
    f.qualityShader = kMabaLevels[u->level].qualityShader;
    f.renderWidth = (int)((float)outW * f.scale + 0.5f);
    f.renderHeight = (int)((float)outH * f.scale + 0.5f);
    if (f.renderWidth < 2) f.renderWidth = 2;
    if (f.renderHeight < 2) f.renderHeight = 2;
    return f;
}

/* Values for the shader's uMabaInputSize and uMabaParams. texW/texH is the allocated size of the
   scene render target; sharpness is 0..1. */
static void MabaUniforms(const MabaFrame* f, int texW, int texH, float sharpness,
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
